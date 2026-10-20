# github-project.ps1: the board as a GitHub Project (v2) over the repository's issues. Status, Priority,
# Size, Wave, Packet and Target date are project fields (names in board.githubProject.fields). The
# issues carry the packet label too, so a REST listing finds them and their open/closed state.

. "$PSScriptRoot/github-common.ps1"

$script:GpMeta = $null

function Initialize-Prov {
    param([Parameter(Mandatory)]$Config)
    $script:PwConfig = $Config
}

function Get-ProvName { 'github-project' }

function Get-PwGpMeta {
    <# Project id, title and fields (id, name, dataType, options by name), read once per run. #>
    if ($script:GpMeta) { return $script:GpMeta }
    $gp = $script:PwConfig.board.githubProject
    $owner = $gp.owner
    if ($owner -eq '@me') { $owner = (Invoke-PwGh api user --jq .login).Trim() }
    $query = 'query($o:String!,$n:Int!){ repositoryOwner(login:$o){ ... on ProjectV2Owner { projectV2(number:$n){ id title url fields(first:100){ nodes{ ... on ProjectV2FieldCommon { id name dataType } ... on ProjectV2SingleSelectField { options { id name } } } } } } } }'
    $r = Invoke-PwGhJson api graphql -f "query=$query" -f "o=$owner" -F "n=$($gp.number)"
    $proj = $r.data.repositoryOwner.projectV2
    if (-not $proj) { Stop-Pw "GitHub Project $owner/$($gp.number) not found or not readable (gh needs the project scope: gh auth refresh -s project)" }
    $fields = @{}
    foreach ($f in $proj.fields.nodes) {
        if (-not $f -or -not $f.ContainsKey('name')) { continue }
        $opts = @{}
        if ($f.ContainsKey('options')) { foreach ($o in $f.options) { $opts[$o.name.ToLowerInvariant()] = $o.id } }
        $fields[$f.name.ToLowerInvariant()] = @{ Id = $f.id; Name = $f.name; DataType = $f.dataType; Options = $opts }
    }
    $script:GpMeta = @{ Id = $proj.id; Title = $proj.title; Url = $proj.url; Owner = $owner; Fields = $fields }
    $script:GpMeta
}

function Get-PwGpFieldValue {
    param([System.Collections.IDictionary]$Row, [string]$FieldName)
    if (-not $FieldName) { return $null }
    $key = $FieldName.ToLowerInvariant()
    if ($Row.Contains($key)) { return $Row[$key] }
    $null
}

function Get-ProvItems {
    $cfg = $script:PwConfig
    $gp = $cfg.board.githubProject
    $fn = $gp.fields
    $owner = $gp.owner
    $rows = Invoke-PwGhJson project item-list $gp.number --owner $owner --format json --limit 3000
    $byNumber = @{}
    foreach ($row in @($rows.items)) {
        $c = $row.content
        if (-not $c -or $c.type -ne 'Issue' -or $c.repository -ne $cfg.repo) { continue }
        $byNumber[[int]$c.number] = $row
    }
    @(foreach ($issue in (Get-PwGhIssues $cfg)) {
            $item = ConvertTo-PwGhItem -Issue $issue -Config $cfg
            $row = $byNumber[[int]$issue.number]
            if ($row) {
                $packetField = Get-PwGpFieldValue $row $fn.packet
                if ($packetField) { $item.Id = $packetField }
                $item.ProjectItemId = $row.id
                $item.Status = Get-PwGpFieldValue $row $fn.status
                $item.Priority = Get-PwGpFieldValue $row $fn.priority
                $item.Size = Get-PwGpFieldValue $row $fn.size
                $item.Wave = Get-PwGpFieldValue $row $fn.wave
                $t = Get-PwGpFieldValue $row $fn.target
                if ($t) { $item.Target = $t }
            }
            if (-not $item.Id) { continue }
            if (-not $item.Status) { $item.Status = if ($item.Closed) { 'Done' } else { 'Backlog' } }
            $item
        })
}

function Test-ProvItemComplete {
    param([Parameter(Mandatory)]$Item)
    [bool]$Item.ProjectItemId
}

function Get-PwGpItemId {
    <# The project item for an issue, adding the issue to the project when it isn't on it. #>
    param([Parameter(Mandatory)]$Item)
    if ($Item.ProjectItemId) { return $Item.ProjectItemId }
    $gp = $script:PwConfig.board.githubProject
    $r = Invoke-PwGhJson project item-add $gp.number --owner $gp.owner --url $Item.Url --format json
    $Item.ProjectItemId = $r.id
    $r.id
}

function Set-ProvFields {
    <# Fields: Status, Priority, Size, Wave, Packet, Target (keys of board.githubProject.fields). #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][hashtable]$Fields)
    $meta = Get-PwGpMeta
    $names = $script:PwConfig.board.githubProject.fields
    $itemId = Get-PwGpItemId $Item
    foreach ($key in $Fields.Keys) {
        $value = [string]$Fields[$key]
        $fieldName = $names[$key.ToLowerInvariant()]
        if (-not $fieldName) { Stop-Pw "board.githubProject.fields has no entry for '$key'" }
        if ($key -eq 'Status' -and $script:Statuses -notcontains $value) { Stop-Pw "unknown status '$value' (one of: $($script:Statuses -join ', '))" }
        $f = $meta.Fields[$fieldName.ToLowerInvariant()]
        if (-not $f) {
            if ($key -eq 'Status') { Stop-Pw "the project has no '$fieldName' field" }
            Write-Warning "the project has no '$fieldName' field; $key not set (board.ps1 setup creates it)"; continue
        }
        if (-not $value) { continue }
        $edit = @('project', 'item-edit', '--id', $itemId, '--project-id', $meta.Id, '--field-id', $f.Id)
        switch ($f.DataType) {
            'SINGLE_SELECT' {
                $opt = $f.Options[$value.ToLowerInvariant()]
                if (-not $opt) { Stop-Pw "the project's '$fieldName' field has no option '$value' (options: $(@($f.Options.Keys) -join ', ')); add it in the project settings" }
                $edit += @('--single-select-option-id', $opt)
            }
            'TEXT' { $edit += @('--text', $value) }
            'NUMBER' { $edit += @('--number', $value) }
            'DATE' { $edit += @('--date', $value) }
            default { Stop-Pw "the project's '$fieldName' field is $($f.DataType); the kit writes single select, text, number or date" }
        }
        [void](Invoke-PwGh @edit)
    }
}

function New-ProvItem {
    param([Parameter(Mandatory)]$Packet, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Body, [string]$PhaseSlug = '', [string]$PhaseTitle = '')
    $cfg = $script:PwConfig
    $labels = @($cfg.labels.packet)
    if ($Packet.Kind -eq 'human') { $labels += $cfg.labels.human }
    foreach ($l in $labels) { [void](Confirm-PwGhLabel -Config $cfg -Name $l) }
    $milestone = if ($PhaseTitle) { Confirm-PwGhMilestone -Config $cfg -Title $PhaseTitle } else { 0 }
    $issue = New-PwGhIssue -Config $cfg -Title $Title -Body $Body -Labels $labels -Milestone $milestone
    $item = ConvertTo-PwGhItem -Issue $issue -Config $cfg
    $f = @{ Status = $Packet.InitialStatus; Packet = $Packet.Id }
    if ($Packet.Priority) { $f.Priority = $Packet.Priority }
    if ($Packet.Size) { $f.Size = $Packet.Size }
    if ($Packet.Wave) { $f.Wave = $Packet.Wave }
    if ($Packet.Target) { $f.Target = $Packet.Target }
    Set-ProvFields -Item $item -Fields $f
    $item.Status = $Packet.InitialStatus
    $item
}

function Update-ProvItem {
    <# Rewrites title and body, and brings Priority, Size, Wave and Target in line. Never Status. #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$Packet, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Body, [string]$PhaseSlug = '', [string]$PhaseTitle = '')
    $milestone = if ($PhaseTitle) { Confirm-PwGhMilestone -Config $script:PwConfig -Title $PhaseTitle } else { 0 }
    Update-PwGhIssue -Config $script:PwConfig -Number $Item.Number -Title $Title -Body $Body -Milestone $milestone
    $f = @{}
    if (-not $Item.ProjectItemId) {
        # Not in the project listing: either joining the project (say, after a switch from github-issues), or
        # added seconds ago and not listed yet. item-add returns the existing item if there is one, so ask it
        # for its Status, and only set the initial state when it has none: closed issues are Done, the rest
        # start from the packet's initial status. Labels from another provider are left as they are.
        $itemId = Get-PwGpItemId $Item
        $statusName = $script:PwConfig.board.githubProject.fields.status
        $q = 'query($id:ID!,$f:String!){ node(id:$id){ ... on ProjectV2Item { fieldValueByName(name:$f){ ... on ProjectV2ItemFieldSingleSelectValue { name } } } } }'
        $current = (Invoke-PwGhJson api graphql -f "query=$q" -f "id=$itemId" -f "f=$statusName").data.node.fieldValueByName
        if (-not $current -or -not $current.name) {
            $f.Status = if ($Item.Closed -and $Item.ClosedReason -ne 'not_planned') { 'Done' } else { $Packet.InitialStatus }
            $f.Priority = $Packet.Priority; $f.Size = $Packet.Size; $f.Wave = $Packet.Wave; $f.Target = $Packet.Target
        }
        $f.Packet = $Packet.Id
    }
    if ($Packet.Priority -and $Packet.Priority -ne $Item.Priority) { $f.Priority = $Packet.Priority }
    if ($Packet.Size -and $Packet.Size -ne $Item.Size) { $f.Size = $Packet.Size }
    if ($Packet.Wave -and $Packet.Wave -ne $Item.Wave) { $f.Wave = $Packet.Wave }
    if ($Packet.Target -and $Packet.Target -ne $Item.Target) { $f.Target = $Packet.Target }
    if ($f.Count) { Set-ProvFields -Item $Item -Fields $f }
}

function Initialize-ProvBoard {
    <# Creates the labels and any missing custom field. It reports, but never changes, the Status
       field's options: rewriting a single-select field's options can clear values already set. #>
    param([switch]$DryRun)
    $cfg = $script:PwConfig
    $gp = $cfg.board.githubProject
    $lines = [System.Collections.Generic.List[string]]::new()
    $created = Initialize-PwGhLabels -Config $cfg -DryRun:$DryRun
    $verb = if ($DryRun) { 'would create' } else { 'created' }
    $lines.Add($(if ($created.Count) { "$verb labels: $($created -join ', ')" } else { 'labels: all present' }))
    $meta = Get-PwGpMeta
    $lines.Add("project: $($meta.Title) ($($meta.Url))")
    $status = $meta.Fields[$gp.fields.status.ToLowerInvariant()]
    if (-not $status) { $lines.Add("MISSING: the project has no '$($gp.fields.status)' field") }
    else {
        $missing = @($script:Statuses | Where-Object { -not $status.Options.ContainsKey($_.ToLowerInvariant()) })
        if ($missing.Count) { $lines.Add("MISSING Status options: $($missing -join ', '). Add them in the project's settings (Status field), spelled exactly so.") }
        else { $lines.Add('Status options: all present') }
    }
    $want = @(
        @('priority', 'SINGLE_SELECT', 'P0,P1,P2,P3'),
        @('size', 'SINGLE_SELECT', (@($cfg.sizes.Keys | Sort-Object { $cfg.sizes[$_] }) -join ',')),
        @('wave', 'TEXT', ''),
        @('packet', 'TEXT', ''),
        @('target', 'DATE', '')
    )
    foreach ($w in $want) {
        $name = $gp.fields[$w[0]]
        if (-not $name) { continue }
        $existing = $meta.Fields[$name.ToLowerInvariant()]
        if ($existing) {
            if ($w[1] -eq 'SINGLE_SELECT' -and $existing.DataType -eq 'SINGLE_SELECT') {
                $miss = @($w[2] -split ',' | Where-Object { -not $existing.Options.ContainsKey($_.ToLowerInvariant()) })
                if ($miss.Count) { $lines.Add("MISSING '$name' options: $($miss -join ', '). Add them in the project's settings.") }
            }
            continue
        }
        if (-not $DryRun) {
            $fc = @('project', 'field-create', $gp.number, '--owner', $gp.owner, '--name', $name, '--data-type', $w[1])
            if ($w[1] -eq 'SINGLE_SELECT') { $fc += @('--single-select-options', $w[2]) }
            [void](Invoke-PwGh @fc)
        }
        $lines.Add("$verb field '$name' ($($w[1]))")
    }
    $script:GpMeta = $null
    $lines
}
