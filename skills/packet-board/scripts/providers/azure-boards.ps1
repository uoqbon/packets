# azure-boards.ps1: the board as Azure Boards work items, while code and pull requests stay on GitHub
# (PR bodies say "Fixes AB#<id>", which the Azure Boards GitHub app links and transitions on merge).
#
# Statuses map to a work item State plus an optional tag (board.azureBoards.statusMap), because the
# stock processes have fewer states than the workflow. Size, wave, phase and the packet marker are
# tags; Priority is the Priority field (P0 = 1 … P3 = 4). Dependencies become Predecessor links.
#
# Auth: AZURE_DEVOPS_EXT_PAT (a PAT with Work Items read & write), else a token from `az login`.
# Calls go to the REST API directly (api-version 7.1; comments 7.1-preview.4), so no az extension is needed.

$script:AbHeaders = $null
$script:AbItemCache = $null
$script:AbCommentsApi = '7.1-preview.4'

function Initialize-Prov {
    param([Parameter(Mandatory)]$Config)
    $script:PwConfig = $Config
}

function Get-ProvName { 'azure-boards' }

function Get-PwAbHeaders {
    if ($script:AbHeaders) { return $script:AbHeaders }
    if ($env:AZURE_DEVOPS_EXT_PAT) {
        $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($env:AZURE_DEVOPS_EXT_PAT)"))
        $script:AbHeaders = @{ Authorization = "Basic $b64" }
        return $script:AbHeaders
    }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Stop-Pw 'Azure Boards needs AZURE_DEVOPS_EXT_PAT (a PAT with Work Items read & write) or the Azure CLI signed in (az login)' }
    $token = & az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $token) { Stop-Pw 'no Azure DevOps token: set AZURE_DEVOPS_EXT_PAT, or run az login' }
    $script:AbHeaders = @{ Authorization = "Bearer $(($token | Select-Object -First 1).Trim())" }
    $script:AbHeaders
}

function Invoke-PwAb {
    <# One REST call. -Path is relative to the project (or to the organization with -OrgLevel). #>
    param(
        [string]$Method = 'GET', [Parameter(Mandatory)][string]$Path, $Body,
        [string]$ContentType = 'application/json', [string]$ApiVersion = '7.1', [switch]$OrgLevel
    )
    $ab = $script:PwConfig.board.azureBoards
    $base = $ab.organization.TrimEnd('/')
    $url = if ($OrgLevel) { "$base/$Path" } else { "$base/$([uri]::EscapeDataString($ab.project))/$Path" }
    $url += $(if ($url.Contains('?')) { '&' } else { '?' }) + "api-version=$ApiVersion"
    $params = @{ Method = $Method; Uri = $url; Headers = (Get-PwAbHeaders); ContentType = "$ContentType; charset=utf-8" }
    if ($null -ne $Body) {
        $json = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 20 }
        $params.Body = [Text.Encoding]::UTF8.GetBytes($json)
    }
    try { $resp = Invoke-WebRequest @params }
    catch {
        $detail = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Stop-Pw "Azure DevOps $Method $Path failed: $detail"
    }
    if (-not $resp.Content) { return $null }
    $resp.Content | ConvertFrom-Json -AsHashtable -Depth 64
}

function Get-PwAbTags {
    param($Fields)
    $raw = if ($Fields.Contains('System.Tags')) { [string]$Fields['System.Tags'] } else { '' }
    @($raw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-PwAbTagValue {
    param([string[]]$Tags, [string]$Prefix)
    $hit = $Tags | Where-Object { $_.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    if ($hit) { $hit.Substring($Prefix.Length) } else { $null }
}

function Get-PwAbStatus {
    <# The workflow status of a work item: a mapped tag wins; else the first status mapped to its state
       without a tag. #>
    param([string]$State, [string[]]$Tags)
    $map = $script:PwConfig.board.azureBoards.statusMap
    foreach ($s in $script:Statuses) {
        $tag = $map[$s].tag
        if ($tag -and ($Tags | Where-Object { $_ -ieq $tag })) { return $s }
    }
    foreach ($s in $script:Statuses) {
        if (-not $map[$s].tag -and $map[$s].state -ieq $State) { return $s }
    }
    if ($script:PwConfig.board.azureBoards.doneStates -contains $State) { return 'Done' }
    'Backlog'
}

function ConvertTo-PwAbItem {
    param([Parameter(Mandatory)]$WorkItem)
    $cfg = $script:PwConfig
    $ab = $cfg.board.azureBoards
    $f = $WorkItem.fields
    $tags = Get-PwAbTags $f
    $state = [string]$f['System.State']
    $title = [string]$f['System.Title']
    $id = if ($title -match "^(?<id>$script:IdPattern)\s*·") { $Matches.id } else { $null }
    $prio = $null
    if ($ab.priorityField -and $f.Contains($ab.priorityField) -and $f[$ab.priorityField]) { $prio = "P$([int]$f[$ab.priorityField] - 1)" }
    $target = $null
    if ($ab.targetDateField -and $f.Contains($ab.targetDateField) -and $f[$ab.targetDateField]) { $target = ([DateTime]$f[$ab.targetDateField]).ToString('yyyy-MM-dd') }
    $body = if ($f.Contains('System.Description')) { [string]$f['System.Description'] } else { '' }
    if (-not $target -and $body -match '\*\*Target:\*\*\s*(?<d>\d{4}-\d{2}-\d{2})') { $target = $Matches.d }
    $done = $ab.doneStates -contains $state
    [pscustomobject]@{
        Id            = $id
        Ref           = [string]$WorkItem.id
        Number        = [int]$WorkItem.id
        DbId          = [long]$WorkItem.id
        NodeId        = $null
        Url           = "$($ab.organization.TrimEnd('/'))/$([uri]::EscapeDataString($ab.project))/_workitems/edit/$($WorkItem.id)"
        Title         = $title
        Body          = $body
        Labels        = $tags
        Kind          = if ($tags | Where-Object { $_ -ieq $cfg.labels.human }) { 'human' } else { 'packet' }
        Closed        = $done
        ClosedReason  = if ($state -ieq 'Removed') { 'not_planned' } elseif ($done) { 'completed' } else { $null }
        UpdatedAt     = $f['System.ChangedDate']
        Milestone     = Get-PwAbTagValue $tags 'phase:'
        Assignees     = @()
        Status        = Get-PwAbStatus -State $state -Tags $tags
        Priority      = $prio
        Size          = Get-PwAbTagValue $tags 'size:'
        Wave          = Get-PwAbTagValue $tags 'wave:'
        Target        = $target
        ProjectItemId = $null
        State         = $state
        Relations     = @()
    }
}

function Get-ProvItems {
    param([switch]$Refresh)
    if ($script:AbItemCache -and -not $Refresh) { return $script:AbItemCache }
    $cfg = $script:PwConfig
    $ab = $cfg.board.azureBoards
    $tag = $cfg.labels.packet.Replace("'", "''")
    $wiql = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.Tags] CONTAINS '$tag' ORDER BY [System.Id]"
    $r = Invoke-PwAb -Method POST -Path '_apis/wit/wiql' -Body @{ query = $wiql }
    $ids = @($r.workItems | ForEach-Object { [int]$_.id })
    $fields = @('System.Id', 'System.Title', 'System.State', 'System.Tags', 'System.Description', 'System.ChangedDate', 'System.WorkItemType')
    if ($ab.priorityField) { $fields += $ab.priorityField }
    if ($ab.targetDateField) { $fields += $ab.targetDateField }
    $items = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $ids.Count; $i += 200) {
        $batch = $ids[$i..([Math]::Min($i + 199, $ids.Count - 1))]
        $res = Invoke-PwAb -Method POST -Path '_apis/wit/workitemsbatch' -Body @{ ids = @($batch); fields = $fields; errorPolicy = 'omit' }
        foreach ($wi in @($res.value)) { if ($wi) { $it = ConvertTo-PwAbItem $wi; if ($it.Id) { $items.Add($it) } } }
    }
    $script:AbItemCache = @($items)
    $script:AbItemCache
}

function Update-PwAbWorkItem {
    <# One JSON-patch update. With -Rev, the patch starts with a test of the revision, so it fails rather
       than overwrite a change someone made after that revision was read. #>
    param([Parameter(Mandatory)][int]$Id, [Parameter(Mandatory)]$Ops, [int]$Rev = 0)
    $script:AbItemCache = $null
    $all = @()
    if ($Rev -gt 0) { $all += @{ op = 'test'; path = '/rev'; value = $Rev } }
    $all += @($Ops)
    Invoke-PwAb -Method PATCH -Path "_apis/wit/workitems/$Id" -Body $all -ContentType 'application/json-patch+json'
}

function Get-PwAbFresh {
    <# The work item's current revision and tags, read just before a write that rewrites the tags. #>
    param([Parameter(Mandatory)][int]$Id)
    $wi = Invoke-PwAb -Path "_apis/wit/workitems/${Id}?fields=System.Tags"
    @{ Rev = [int]$wi.rev; Tags = @(Get-PwAbTags $wi.fields) }
}

function Get-PwAbStatusTags {
    $map = $script:PwConfig.board.azureBoards.statusMap
    @($script:Statuses | ForEach-Object { $map[$_].tag } | Where-Object { $_ })
}

function Get-PwAbFieldOps {
    <# JSON-patch operations for Status, Priority, Size, Wave and Target on an item with these tags. #>
    param([Parameter(Mandatory)][hashtable]$Fields, [string[]]$Tags = @(), [switch]$ForceTags)
    $ab = $script:PwConfig.board.azureBoards
    $ops = [System.Collections.Generic.List[object]]::new()
    $newTags = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $Tags) { $newTags.Add($t) }
    $tagsChanged = [bool]$ForceTags
    foreach ($name in $Fields.Keys) {
        $value = [string]$Fields[$name]
        if (-not $value) { continue }
        if ($name -eq 'Status') {
            if ($script:Statuses -notcontains $value) { Stop-Pw "unknown status '$value' (one of: $($script:Statuses -join ', '))" }
            $m = $ab.statusMap[$value]
            $ops.Add(@{ op = 'add'; path = '/fields/System.State'; value = $m.state })
            foreach ($st in (Get-PwAbStatusTags)) { [void]$newTags.RemoveAll([Predicate[string]] { param($x) $x -ieq $st }) }
            if ($m.tag) { $newTags.Add($m.tag) }
            $tagsChanged = $true
        }
        elseif ($name -eq 'Priority') {
            if ($value -notmatch '^P(?<n>[0-3])$') { Stop-Pw "Priority must be P0-P3 (got '$value')" }
            if ($ab.priorityField) { $ops.Add(@{ op = 'add'; path = "/fields/$($ab.priorityField)"; value = [int]$Matches.n + 1 }) }
        }
        elseif ($name -in 'Size', 'Wave') {
            $prefix = "$($name.ToLowerInvariant()):"
            [void]$newTags.RemoveAll([Predicate[string]] { param($x) $x.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })
            $newTags.Add("$prefix$value")
            $tagsChanged = $true
        }
        elseif ($name -eq 'Target') {
            if ($ab.targetDateField) { $ops.Add(@{ op = 'add'; path = "/fields/$($ab.targetDateField)"; value = "$($value)T00:00:00Z" }) }
        }
        else { Stop-Pw "azure-boards has no field '$name' (Status, Priority, Size, Wave, Target)" }
    }
    if ($tagsChanged) { $ops.Add(@{ op = 'add'; path = '/fields/System.Tags'; value = (($newTags | Select-Object -Unique) -join '; ') }) }
    , $ops
}

function Set-ProvFields {
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][hashtable]$Fields)
    $fresh = Get-PwAbFresh $Item.Number
    $ops = Get-PwAbFieldOps -Fields $Fields -Tags $fresh.Tags
    if ($ops.Count) { [void](Update-PwAbWorkItem -Id $Item.Number -Ops $ops -Rev $fresh.Rev) }
}

function Get-PwAbDescriptionOps {
    param([Parameter(Mandatory)][string]$Body)
    $ab = $script:PwConfig.board.azureBoards
    if ($ab.markdown) {
        return @(
            @{ op = 'add'; path = '/fields/System.Description'; value = $Body },
            @{ op = 'add'; path = '/multilineFieldsFormat/System.Description'; value = 'Markdown' }
        )
    }
    $html = '<div style="white-space: pre-wrap; font-family: monospace">' + [System.Net.WebUtility]::HtmlEncode($Body) + '</div>'
    @(@{ op = 'add'; path = '/fields/System.Description'; value = $html })
}

function New-ProvItem {
    param([Parameter(Mandatory)]$Packet, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Body, [string]$PhaseSlug = '', [string]$PhaseTitle = '')
    $cfg = $script:PwConfig
    $ab = $cfg.board.azureBoards
    $type = if ($Packet.Kind -eq 'human') { $ab.humanWorkItemType } else { $ab.workItemType }
    $tags = @($cfg.labels.packet)
    if ($Packet.Kind -eq 'human') { $tags += $cfg.labels.human }
    if ($PhaseSlug) { $tags += "phase:$PhaseSlug" }
    $ops = [System.Collections.Generic.List[object]]::new()
    $ops.Add(@{ op = 'add'; path = '/fields/System.Title'; value = $Title })
    foreach ($o in (Get-PwAbDescriptionOps $Body)) { $ops.Add($o) }
    $ops.Add(@{ op = 'add'; path = '/fields/System.Tags'; value = ($tags -join '; ') })
    if ($ab.areaPath) { $ops.Add(@{ op = 'add'; path = '/fields/System.AreaPath'; value = $ab.areaPath }) }
    if ($ab.iterationPath) { $ops.Add(@{ op = 'add'; path = '/fields/System.IterationPath'; value = $ab.iterationPath }) }
    $wi = Invoke-PwAb -Method POST -Path "_apis/wit/workitems/`$$([uri]::EscapeDataString($type))" -Body @($ops) -ContentType 'application/json-patch+json'
    $script:AbItemCache = $null
    $item = ConvertTo-PwAbItem $wi
    $f = @{ Status = $Packet.InitialStatus }
    if ($Packet.Priority) { $f.Priority = $Packet.Priority }
    if ($Packet.Size) { $f.Size = $Packet.Size }
    if ($Packet.Wave) { $f.Wave = $Packet.Wave }
    if ($Packet.Target) { $f.Target = $Packet.Target }
    Set-ProvFields -Item $item -Fields $f
    $item.Status = $Packet.InitialStatus
    $item
}

function Update-ProvItem {
    <# Rewrites title and description, and brings Priority, Size, Wave and Target in line. Never Status. #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$Packet, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Body, [string]$PhaseSlug = '', [string]$PhaseTitle = '')
    $f = @{}
    if ($Packet.Priority -and $Packet.Priority -ne $Item.Priority) { $f.Priority = $Packet.Priority }
    if ($Packet.Size -and $Packet.Size -ne $Item.Size) { $f.Size = $Packet.Size }
    if ($Packet.Wave -and $Packet.Wave -ne $Item.Wave) { $f.Wave = $Packet.Wave }
    if ($Packet.Target -and $Packet.Target -ne $Item.Target) { $f.Target = $Packet.Target }
    $fresh = Get-PwAbFresh $Item.Number
    $tags = @($fresh.Tags)
    $retag = $false
    if ($PhaseSlug -and -not ($tags | Where-Object { $_ -ieq "phase:$PhaseSlug" })) {
        $tags = @($tags | Where-Object { -not $_.StartsWith('phase:', [StringComparison]::OrdinalIgnoreCase) }) + "phase:$PhaseSlug"
        $retag = $true
    }
    $ops = [System.Collections.Generic.List[object]]::new()
    $ops.Add(@{ op = 'add'; path = '/fields/System.Title'; value = $Title })
    foreach ($o in (Get-PwAbDescriptionOps $Body)) { $ops.Add($o) }
    foreach ($o in (Get-PwAbFieldOps -Fields $f -Tags $tags -ForceTags:$retag)) { $ops.Add($o) }
    [void](Update-PwAbWorkItem -Id $Item.Number -Ops $ops -Rev $fresh.Rev)
}

function Get-ProvComments {
    param([Parameter(Mandatory)][string]$Ref)
    $all = [System.Collections.Generic.List[object]]::new()
    $token = $null
    do {
        $path = "_apis/wit/workItems/$Ref/comments?`$top=200"
        if ($token) { $path += "&continuationToken=$([uri]::EscapeDataString($token))" }
        $r = Invoke-PwAb -Path $path -ApiVersion $script:AbCommentsApi
        foreach ($c in @($r.comments)) {
            if ($c.ContainsKey('isDeleted') -and $c.isDeleted) { continue }
            $all.Add([pscustomobject]@{ Id = [long]$c.id; CreatedAt = [DateTimeOffset]$c.createdDate; Body = [string]$c.text; Author = $c.createdBy.uniqueName })
        }
        $token = if ($r.ContainsKey('continuationToken')) { $r.continuationToken } else { $null }
    } while ($token)
    @($all)
}

function Add-ProvComment {
    param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)][string]$Body)
    $c = Invoke-PwAb -Method POST -Path "_apis/wit/workItems/$Ref/comments?format=markdown" -Body @{ text = $Body } -ApiVersion $script:AbCommentsApi
    [pscustomobject]@{ Id = [long]$c.id; CreatedAt = [DateTimeOffset]$c.createdDate; Body = [string]$c.text; Url = $null }
}

function Remove-ProvComment {
    param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)]$CommentId)
    [void](Invoke-PwAb -Method DELETE -Path "_apis/wit/workItems/$Ref/comments/$CommentId" -ApiVersion $script:AbCommentsApi)
}

function Get-ProvRefText {
    param([Parameter(Mandatory)]$Item)
    "Fixes AB#$($Item.Number)"
}

$script:AbAccount = $null

function Get-ProvCurrentUser {
    <# The signed-in account's unique name (usually an email), which comments carry as createdBy.uniqueName. #>
    if (-not $script:AbAccount) {
        $me = Invoke-PwAb -Path '_apis/connectionData' -OrgLevel -ApiVersion '7.1-preview'
        $script:AbAccount = $me.authenticatedUser.properties.Account['$value']
    }
    $script:AbAccount
}

function Set-ProvAssignee {
    param([Parameter(Mandatory)][string]$Ref)
    $account = Get-ProvCurrentUser
    if (-not $account) { Stop-Pw "could not assign AB#${Ref}: no account on the connection" }
    [void](Update-PwAbWorkItem -Id ([int]$Ref) -Ops @(@{ op = 'add'; path = '/fields/System.AssignedTo'; value = $account }))
}

function Get-PwAbRelations {
    param([Parameter(Mandatory)][int]$Id)
    $wi = Invoke-PwAb -Path "_apis/wit/workitems/${Id}?`$expand=relations"
    @($wi.relations | Where-Object { $_ })
}

function Add-PwAbLinks {
    param([Parameter(Mandatory)][int]$Id, [Parameter(Mandatory)][string]$Rel, [int[]]$Targets)
    $org = $script:PwConfig.board.azureBoards.organization.TrimEnd('/')
    $existing = @(Get-PwAbRelations $Id | Where-Object { $_.rel -eq $Rel } | ForEach-Object { [int](($_.url -split '/')[-1]) })
    $ops = @(foreach ($t in $Targets) {
            if ($existing -contains $t) { continue }
            @{ op = 'add'; path = '/relations/-'; value = @{ rel = $Rel; url = "$org/_apis/wit/workItems/$t" } }
        })
    if ($ops.Count) { [void](Update-PwAbWorkItem -Id $Id -Ops $ops) }
    $ops.Count
}

function Set-ProvParent {
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][string]$EpicRef)
    $id = [int]($EpicRef -replace '^AB#', '')
    (Add-PwAbLinks -Id $Item.Number -Rel 'System.LinkTypes.Hierarchy-Reverse' -Targets @($id)) -gt 0
}

function Set-ProvDependencies {
    <# Predecessor links for the packet's Depends on line. The packet file stays the source of truth. #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$DependencyItems)
    if (@($DependencyItems).Count -eq 0) { return 0 }
    Add-PwAbLinks -Id $Item.Number -Rel 'System.LinkTypes.Dependency-Reverse' -Targets @($DependencyItems | ForEach-Object { $_.Number })
}

function Initialize-ProvBoard {
    <# Checks that the work item types exist and have every mapped state. Tags need no setup. #>
    param([switch]$DryRun)
    $ab = $script:PwConfig.board.azureBoards
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($type in @($ab.workItemType, $ab.humanWorkItemType | Select-Object -Unique)) {
        $states = Invoke-PwAb -Path "_apis/wit/workitemtypes/$([uri]::EscapeDataString($type))/states"
        $names = @($states.value | ForEach-Object { $_.name })
        if (-not $names) { $lines.Add("MISSING: work item type '$type' not found in $($ab.project)"); continue }
        $mapped = @($script:Statuses | ForEach-Object { $ab.statusMap[$_].state } | Select-Object -Unique)
        $missing = @($mapped | Where-Object { $names -notcontains $_ })
        if ($missing.Count) { $lines.Add("MISSING states on '$type': $($missing -join ', ') (it has: $($names -join ', ')). Fix board.azureBoards.statusMap.") }
        else { $lines.Add("'$type' has every mapped state ($($mapped -join ', '))") }
    }
    if ($ab.priorityField -ne 'Microsoft.VSTS.Common.Priority') { $lines.Add("priority field: $($ab.priorityField)") }
    $lines.Add('tags (packet, status:*, size:*, wave:*, phase:*) are created on first use')
    # Review follow-ups are GitHub issues even here (the code is on GitHub), and a contract question also
    # carries the needs-human label, so both labels must exist on the repository.
    $created = Initialize-PwGhLabels -Config $script:PwConfig -Keys 'needsHuman', 'followUp' -DryRun:$DryRun
    $lines.Add($(if ($created.Count) { "$(if ($DryRun) { 'would create' } else { 'created' }) GitHub labels on $($script:PwConfig.repo): $($created -join ', ')" } else { "GitHub labels for follow-ups: all present on $($script:PwConfig.repo)" }))
    $lines
}
