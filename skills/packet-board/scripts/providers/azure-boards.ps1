# azure-boards.ps1: the board as Azure Boards work items, while code and pull requests stay on GitHub
# (PR bodies say "Fixes AB#<id>", which the Azure Boards GitHub app links and transitions on merge).
#
# Statuses map to a work item State plus an optional tag (board.azureBoards.statusMap, and taskStatusMap
# for the task type, whose states differ), because the stock processes have fewer states than the
# workflow. Size, wave, phase and the packet marker are tags; Priority is the Priority field (P0 = 1 …
# P3 = 4). Dependencies become Predecessor links.
#
# Items form the process's hierarchy, Epic > Feature > User Story > Task, one level at a time, as Azure
# Boards advises (under a link between items of one level, only the leaf shows on boards, and the backlog
# can't be reordered). The phase's plan names its root, an existing epic, feature or story, and sync builds
# the tree under it: under an epic, one feature per workstream holds that workstream's packets as stories;
# under a feature, the packets are its stories; under a story, its tasks. A human task sits under the story
# it unblocks (or, failing that, the one it follows), or beside the packets under a story root. Sync links
# an item that has no parent; it moves one that has another parent only with -Force.
#
# Auth: AZURE_DEVOPS_EXT_PAT (a PAT with Work Items read & write), else a token from `az login`.
# Calls go to the REST API directly (api-version 7.1; comments 7.1-preview.4), so no az extension is needed.

$script:AbHeaders = $null
$script:AbItemCache = $null
$script:AbCommentsApi = '7.1-preview.4'
# Each phase's tree (Resolve-ProvHierarchy), by phase slug: New-ProvItem reads the packets' type from it.
$script:AbTrees = @{}
# The Features found or created under each epic, by "<epic id>|<name>" (keys ignore case), shared by every
# phase's tree: phases under one epic share a workstream's Feature. Planned holds those a dry run would create.
$script:AbFeatures = @{}
$script:AbFeaturesPlanned = @{}

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

function Get-PwAbStatusMap {
    <# The status map for a work item type: taskStatusMap for the task type when the config sets one (a
       task's states differ from a story's in every stock process), else statusMap. #>
    param([string]$Type)
    $ab = $script:PwConfig.board.azureBoards
    if ($Type -and $Type -ieq $ab.taskWorkItemType -and $ab.Contains('taskStatusMap') -and $ab.taskStatusMap) { return $ab.taskStatusMap }
    $ab.statusMap
}

function Get-PwAbStatus {
    <# The workflow status of a work item: a mapped tag wins; else the first status mapped to its state
       without a tag. Optional keys (a status's tag, a work item's relations) are read by index: under
       strict mode, a dot on a missing key throws. #>
    param([string]$State, [string[]]$Tags, [string]$Type)
    $map = Get-PwAbStatusMap $Type
    foreach ($s in $script:Statuses) {
        $tag = $map[$s]['tag']
        if ($tag -and ($Tags | Where-Object { $_ -ieq $tag })) { return $s }
    }
    foreach ($s in $script:Statuses) {
        if (-not $map[$s]['tag'] -and $map[$s].state -ieq $State) { return $s }
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
    $type = if ($f.Contains('System.WorkItemType')) { [string]$f['System.WorkItemType'] } else { '' }
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
        Status        = Get-PwAbStatus -State $state -Tags $tags -Type $type
        Priority      = $prio
        Size          = Get-PwAbTagValue $tags 'size:'
        Wave          = Get-PwAbTagValue $tags 'wave:'
        Target        = $target
        ProjectItemId = $null
        State         = $state
        Type          = $type
        Relations     = @()
    }
}

function Get-PwAbWorkItems {
    <# Work items by id with the named fields, 200 to a call; ids that no longer exist are left out. #>
    param([int[]]$Ids = @(), [Parameter(Mandatory)][string[]]$Fields)
    $found = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Ids.Count; $i += 200) {
        $batch = $Ids[$i..([Math]::Min($i + 199, $Ids.Count - 1))]
        $res = Invoke-PwAb -Method POST -Path '_apis/wit/workitemsbatch' -Body @{ ids = @($batch); fields = $Fields; errorPolicy = 'omit' }
        foreach ($wi in @($res.value)) { if ($wi) { $found.Add($wi) } }
    }
    @($found)
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
    foreach ($wi in (Get-PwAbWorkItems -Ids $ids -Fields $fields)) { $it = ConvertTo-PwAbItem $wi; if ($it.Id) { $items.Add($it) } }
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
    <# The work item's current revision, tags and type, read just before a write that rewrites the tags. #>
    param([Parameter(Mandatory)][int]$Id)
    $wi = Invoke-PwAb -Path "_apis/wit/workitems/${Id}?fields=System.Tags,System.WorkItemType"
    @{ Rev = [int]$wi.rev; Tags = @(Get-PwAbTags $wi.fields); Type = [string]$wi.fields['System.WorkItemType'] }
}

function Get-PwAbStatusTags {
    <# Every status tag of both maps, so a status change clears one the other map set. #>
    $ab = $script:PwConfig.board.azureBoards
    $maps = @($ab.statusMap) + @(if ($ab.Contains('taskStatusMap') -and $ab.taskStatusMap) { $ab.taskStatusMap })
    @(foreach ($map in $maps) { foreach ($s in $script:Statuses) { $map[$s]['tag'] } }) | Where-Object { $_ } | Select-Object -Unique
}

function Get-PwAbFieldOps {
    <# JSON-patch operations for Status, Priority, Size, Wave and Target on an item of this type with these tags. #>
    param([Parameter(Mandatory)][hashtable]$Fields, [string[]]$Tags = @(), [string]$Type, [switch]$ForceTags)
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
            $m = (Get-PwAbStatusMap $Type)[$value]
            $ops.Add(@{ op = 'add'; path = '/fields/System.State'; value = $m.state })
            foreach ($st in (Get-PwAbStatusTags)) { [void]$newTags.RemoveAll([Predicate[string]] { param($x) $x -ieq $st }) }
            if ($m['tag']) { $newTags.Add($m['tag']) }
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
    $ops = Get-PwAbFieldOps -Fields $Fields -Tags $fresh.Tags -Type $fresh.Type
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
    # A packet is a story, or a task under a story root: the phase's tree says which.
    $tree = $script:AbTrees[$PhaseSlug]
    $type = if ($Packet.Kind -eq 'human') { $ab.humanWorkItemType } elseif ($tree) { $tree.PacketType } else { $ab.workItemType }
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
    foreach ($o in (Get-PwAbFieldOps -Fields $f -Tags $tags -Type $fresh.Type -ForceTags:$retag)) { $ops.Add($o) }
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

function Get-PwAbWorkItem {
    <# One work item with all its fields and its relations. #>
    param([Parameter(Mandatory)][int]$Id)
    Invoke-PwAb -Path "_apis/wit/workitems/${Id}?`$expand=relations"
}

function Get-PwAbRelations {
    param([Parameter(Mandatory)][int]$Id)
    @((Get-PwAbWorkItem $Id)['relations'] | Where-Object { $_ })
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

function Get-PwAbTypeStates {
    <# The state names of a work item type, and why there are none: Azure DevOps answers a type the project
       doesn't have with an error, or with no states. #>
    param([Parameter(Mandatory)][string]$Type)
    try {
        $r = Invoke-PwAb -Path "_apis/wit/workitemtypes/$([uri]::EscapeDataString($Type))/states"
        $names = @($r['value'] | Where-Object { $_ } | ForEach-Object { $_['name'] })
        @{ Names = $names; Error = $(if ($names.Count) { $null } else { 'no states' }) }
    }
    catch [PwError] { @{ Names = @(); Error = $_.Exception.Message } }
}

function Get-PwAbLevels {
    <# The hierarchy's levels, top down, each with its work item type. A process without features (Basic:
       Epic > Issue > Task) has no feature level. #>
    $ab = $script:PwConfig.board.azureBoards
    $levels = [ordered]@{ epic = $ab.epicWorkItemType }
    if ($ab.featureWorkItemType) { $levels.feature = $ab.featureWorkItemType }
    $levels.story = $ab.workItemType
    $levels.task = $ab.taskWorkItemType
    $levels
}

function Resolve-ProvHierarchy {
    <# Where each packet and human task of a phase goes under the plan's root item, worked out before sync
       writes anything. The root must exist and be of the type its line names, or this stops sync. Each item
       sits one level below its parent: a packet under the root, or under its workstream's feature when the
       root is an epic; a human task (a task, unless humanWorkItemType is another level's type) under the
       first packet that waits on it, else the first one it waits on. -Packets are the phase's packets and human tasks in dependency order. Returns the tree
       for Set-ProvHierarchy, and keeps it for New-ProvItem, which creates packets of its PacketType. #>
    param([Parameter(Mandatory)]$Phase, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Packets)
    $cfg = $script:PwConfig
    $ab = $cfg.board.azureBoards
    $levels = Get-PwAbLevels
    $names = @($levels.Keys)
    $tree = [pscustomobject]@{ Phase = $Phase; RootId = 0; RootType = $null; PacketType = $ab.workItemType; Places = @(); Features = @{} }
    $script:AbTrees[$Phase.Slug] = $tree
    $root = $Phase.Root
    if (-not $root) { return $tree }
    # Checked here, not with the config: a board without a root line never builds a tree, and a config from
    # before the hierarchy (packets as tasks, say) keeps working until a plan names a root.
    $types = @($levels.Values)
    if (@($types | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique).Count -ne $types.Count) { Stop-Pw "$($Phase.Path) names a root, and the tree under it needs a different work item type at each level (board.azureBoards epic, feature, story and task types; got $($types -join ', '))" }
    if (-not $levels.Contains($root.Level)) { Stop-Pw "$($Phase.Path) names a feature as its root (**$($root.Line):** $($root.Ref)), but board.azureBoards.featureWorkItemType is empty: this process has no features, so name an epic or a story" }
    $rootId = [int]($root.Ref -replace '^(AB)?#', '')
    $wi = Get-PwAbWorkItem $rootId
    $rootType = [string]$wi.fields['System.WorkItemType']
    if ($rootType -ine $levels[$root.Level]) { Stop-Pw "$($Phase.Path) says **$($root.Line):** $($root.Ref), but AB#$rootId is of type ${rootType}: name a work item of type $($levels[$root.Level]) there, or use the line for AB#${rootId}'s type (**Epic:**, **Feature:** or **User Story:**)" }
    if (@(Get-PwAbTags $wi.fields) | Where-Object { $_ -ieq $cfg.labels.packet }) { Stop-Pw "$($Phase.Path) names AB#$rootId as its root, but AB#$rootId is a packet's own item: the root is the epic, feature or story the phase belongs to" }
    $tree.RootId = $rootId
    $tree.RootType = $rootType
    $rootIdx = $names.IndexOf($root.Level)
    $packetLevel = if ($root.Level -eq 'story') { 'task' } else { 'story' }
    $tree.PacketType = $levels[$packetLevel]
    $humanLevel = $names | Where-Object { $levels[$_] -ieq $ab.humanWorkItemType } | Select-Object -First 1
    if (-not $humanLevel) { $humanLevel = 'task' }
    if ($packetLevel -eq 'task') {
        # Packets move through every status; task states differ from story states, so check them now
        # rather than fail at Ready to merge.
        $map = Get-PwAbStatusMap $tree.PacketType
        $have = @((Get-PwAbTypeStates $tree.PacketType).Names)
        $missing = @($script:Statuses | ForEach-Object { $map[$_].state } | Select-Object -Unique | Where-Object { $have -notcontains $_ })
        if ($missing.Count) { Stop-Pw "under AB#$rootId (type $rootType) the packets are of type $($tree.PacketType), which has no state $($missing -join ', ') (it has: $($have -join ', ')): set board.azureBoards.taskStatusMap (providers.md has starting points)" }
    }
    $phasePackets = @($Packets | Where-Object { $_.Kind -eq 'packet' })
    $tree.Places = @(foreach ($p in $Packets) {
            $level = if ($p.Kind -eq 'human') { $humanLevel } else { $packetLevel }
            $idx = $names.IndexOf($level)
            # A human task is created as humanWorkItemType, whatever level it sits at.
            $type = if ($p.Kind -eq 'human') { $ab.humanWorkItemType } else { $levels[$level] }
            $place = [pscustomobject]@{ Id = $p.Id; Type = $type; Parent = $null; Feature = $null; Note = $null }
            if ($idx -eq $rootIdx + 1) { $place.Parent = 'root' }
            elseif ($idx -gt $rootIdx + 1 -and $names[$idx - 1] -eq 'feature') {
                $place.Parent = 'feature'
                $place.Feature = if ($p.Workstream) { $p.Workstream.Trim() } else { $Phase.Title }
            }
            elseif ($idx -gt $rootIdx + 1 -and $names[$idx - 1] -eq 'story') {
                $story = @(@($phasePackets | Where-Object { $_.DependsOn -contains $p.Id }) + @(foreach ($d in $p.DependsOn) { $phasePackets | Where-Object { $_.Id -eq $d } })) | Select-Object -First 1
                if ($story) { $place.Parent = $story.Id }
                else { $place.Note = "$($p.Id) (type $($place.Type)) has no $($levels.story) to sit under: no packet of $($Phase.Slug) waits on it or comes before it. Give it a Depends on, or link it by hand" }
            }
            else { $place.Note = "$($p.Id) (type $($place.Type)) can't sit under AB#$rootId (type $rootType); link it by hand" }
            $place
        })
    $wanted = @($tree.Places | Where-Object { $_.Feature } | ForEach-Object { $_.Feature } | Select-Object -Unique)
    if ($wanted.Count) {
        # A config from before the hierarchy fills in the Feature level by default, which a Basic project
        # doesn't have: stop here, before any write, rather than when the first Feature is created.
        $featureStates = Get-PwAbTypeStates $ab.featureWorkItemType
        if (-not $featureStates.Names.Count) { Stop-Pw "under the $rootType AB#$rootId sync puts a $($ab.featureWorkItemType) per workstream, but the project has no work item type '$($ab.featureWorkItemType)' ($($featureStates.Error)): set board.azureBoards.featureWorkItemType to the process's feature type, or to `"`" where it has none (Basic)" }
        # A feature already under the epic with the workstream's name is reused; open ones first, so a closed
        # one is reused only when no open one has that name. A Removed one never is: Azure Boards hides it.
        # Another phase's tree may have found it already.
        $children = @($wi['relations'] | Where-Object { $_ -and $_.rel -eq 'System.LinkTypes.Hierarchy-Forward' } | ForEach-Object { [int](($_.url -split '/')[-1]) })
        $kids = @(Get-PwAbWorkItems -Ids $children -Fields @('System.Id', 'System.Title', 'System.WorkItemType', 'System.State') |
                Where-Object { [string]$_.fields['System.WorkItemType'] -ieq $ab.featureWorkItemType -and [string]$_.fields['System.State'] -ine 'Removed' } |
                Sort-Object { $ab.doneStates -contains [string]$_.fields['System.State'] }, { [int]$_.id })
        foreach ($name in $wanted) {
            $key = "$rootId|$name"
            if (-not $script:AbFeatures[$key]) {
                $hit = $kids | Where-Object { ([string]$_.fields['System.Title']).Trim() -ieq $name } | Select-Object -First 1
                if ($hit) { $script:AbFeatures[$key] = [int]$hit.id }
            }
            $tree.Features[$name] = [int]$script:AbFeatures[$key]
        }
    }
    $tree
}

function Set-ProvHierarchy {
    <# Builds a phase's tree (Resolve-ProvHierarchy): creates the workstream features the epic lacks, then
       links each item that has no parent under its place. An item under another parent (an item has only
       one) was put there on the board, or by an older layout: it is named and left there, and -Force moves
       it, as -Force makes the packet files win over board edits elsewhere in sync. An item whose type
       doesn't fit its place is named and left where it is. -DryRun says what it would do and writes nothing. #>
    param([Parameter(Mandatory)]$Tree, [Parameter(Mandatory)][hashtable]$ItemsById, [switch]$DryRun, [switch]$Force)
    if (-not $Tree.RootId) { return }
    $cfg = $script:PwConfig
    $ab = $cfg.board.azureBoards
    $org = $ab.organization.TrimEnd('/')
    $ph = $Tree.Phase
    $parentRel = 'System.LinkTypes.Hierarchy-Reverse'
    # A Feature is created only for an item this run puts under it: a new item, one with no parent, or any
    # item with -Force. Without that, a board kept in another layout would get empty Features, again each
    # sync after the owner removes them.
    $needed = @{}
    foreach ($place in $Tree.Places) {
        if ($place.Parent -ne 'feature' -or $place.Note -or $needed[$place.Feature]) { continue }
        $item = $ItemsById[$place.Id]
        if ($Force -or -not $item) { $needed[$place.Feature] = $true; continue }
        $w = Get-PwAbWorkItem $item.Number
        if ([string]$w.fields['System.WorkItemType'] -ine $place.Type) { continue }
        if (-not @($w['relations'] | Where-Object { $_ -and $_.rel -eq $parentRel }).Count) { $needed[$place.Feature] = $true }
    }
    foreach ($name in @($Tree.Features.Keys | Sort-Object)) {
        if ($Tree.Features[$name]) { continue }
        # A Feature an earlier phase's tree created (or, in a dry run, would create) in this sync.
        $key = "$($Tree.RootId)|$name"
        if ($script:AbFeatures[$key]) { $Tree.Features[$name] = [int]$script:AbFeatures[$key]; continue }
        if (-not $needed[$name]) { continue }
        if ($DryRun) {
            if (-not $script:AbFeaturesPlanned[$key]) { "would create $($ab.featureWorkItemType) '$name' under AB#$($Tree.RootId)" }
            $script:AbFeaturesPlanned[$key] = $true
            continue
        }
        $link = "[$($ph.Path)](https://github.com/$($cfg.repo)/blob/$($cfg.defaultBranch)/$($ph.Path))"
        # The phase's own Feature (its packets without a workstream) carries its phase tag; a workstream's
        # Feature may hold the packets of several phases, so it carries none.
        $own = $name -ieq $ph.Title
        $text = if ($own) { "The packets of $($ph.Title) ($link) that name no workstream." } else { "Workstream ${name}: the packets that name it, in every phase under this $($ab.epicWorkItemType) (first $($ph.Title), $link)." }
        $text += " Board sync puts them under this $($ab.featureWorkItemType); it never edits or deletes it."
        $ops = [System.Collections.Generic.List[object]]::new()
        $ops.Add(@{ op = 'add'; path = '/fields/System.Title'; value = $name })
        foreach ($o in (Get-PwAbDescriptionOps $text)) { $ops.Add($o) }
        if ($own) { $ops.Add(@{ op = 'add'; path = '/fields/System.Tags'; value = "phase:$($ph.Slug)" }) }
        if ($ab.areaPath) { $ops.Add(@{ op = 'add'; path = '/fields/System.AreaPath'; value = $ab.areaPath }) }
        $ops.Add(@{ op = 'add'; path = '/relations/-'; value = @{ rel = $parentRel; url = "$org/_apis/wit/workItems/$($Tree.RootId)" } })
        $wi = Invoke-PwAb -Method POST -Path "_apis/wit/workitems/`$$([uri]::EscapeDataString($ab.featureWorkItemType))" -Body @($ops) -ContentType 'application/json-patch+json'
        $Tree.Features[$name] = [int]$wi.id
        $script:AbFeatures[$key] = [int]$wi.id
        "created $($ab.featureWorkItemType) '$name' AB#$($wi.id) under AB#$($Tree.RootId)"
    }
    foreach ($place in $Tree.Places) {
        if ($place.Note) { "note: $($place.Note)"; continue }
        # The parent: the root, a workstream feature, or the packet whose story a human task sits under.
        $story = if ($place.Parent -notin 'root', 'feature') { $ItemsById[$place.Parent] } else { $null }
        $target = if ($place.Parent -eq 'root') { $Tree.RootId } elseif ($place.Parent -eq 'feature') { [int]$Tree.Features[$place.Feature] } elseif ($story) { $story.Number } else { 0 }
        $label = if ($place.Parent -eq 'root') { "AB#$target" } else {
            $(if ($place.Parent -eq 'feature') { "$($ab.featureWorkItemType) '$($place.Feature)'" } else { $place.Parent }) + $(if ($target) { " AB#$target" } else { ' (new)' })
        }
        if ($story -and $story.Type -and $story.Type -ine $Tree.PacketType) { "note: $($place.Id) was left where it is: $label, the story it belongs under, is of type $($story.Type), not $($Tree.PacketType)"; continue }
        $item = $ItemsById[$place.Id]
        if (-not $item) { if ($DryRun) { "would put $($place.Id) (new) under $label" }; continue }
        $wi = Get-PwAbWorkItem $item.Number
        $type = [string]$wi.fields['System.WorkItemType']
        if ($type -ine $place.Type) { "note: $($place.Id) AB#$($item.Number) is of type $type, but its place under $label takes a work item of type $($place.Type): change its type on the board, then sync again"; continue }
        $rels = @($wi['relations'])
        $parents = @(for ($i = 0; $i -lt $rels.Count; $i++) {
                if ($rels[$i] -and $rels[$i].rel -eq $parentRel) { [pscustomobject]@{ Index = $i; Id = [int](($rels[$i].url -split '/')[-1]) } }
            })
        if ($target -and $parents.Count -eq 1 -and $parents[0].Id -eq $target) { continue }
        $from = ($parents | ForEach-Object { "AB#$($_.Id)" }) -join ', '
        if ($from -and -not $Force) { "note: $($place.Id) AB#$($item.Number) is under $from, and its place is under ${label}: sync -Phase $($ph.Slug) -Force moves it (with -DryRun, it shows every move first)"; continue }
        $verb = if ($parents.Count) { 'move' } else { 'put' }
        if ($DryRun) { "would $verb $($place.Id) AB#$($item.Number) under $label$(if ($from) { " (now under $from)" })"; continue }
        # Outside a dry run every feature and item exists by now.
        if (-not $target) { "note: $($place.Id) AB#$($item.Number) was left where it is: $label isn't on the board"; continue }
        # The test of the revision keeps a change made since the read above from being overwritten.
        $ops = @(@($parents | Sort-Object Index -Descending | ForEach-Object { @{ op = 'remove'; path = "/relations/$($_.Index)" } }) +
            @(@{ op = 'add'; path = '/relations/-'; value = @{ rel = $parentRel; url = "$org/_apis/wit/workItems/$target" } }))
        [void](Update-PwAbWorkItem -Id $item.Number -Ops $ops -Rev ([int]$wi.rev))
        "$(if ($from) { 'moved' } else { 'linked' }) $($place.Id) AB#$($item.Number) under $label$(if ($from) { " (was under $from)" })"
    }
}

function Set-ProvDependencies {
    <# Predecessor links for the packet's Depends on line. The packet file stays the source of truth. #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$DependencyItems)
    if (@($DependencyItems).Count -eq 0) { return 0 }
    Add-PwAbLinks -Id $Item.Number -Rel 'System.LinkTypes.Dependency-Reverse' -Targets @($DependencyItems | ForEach-Object { $_.Number })
}

function Initialize-ProvBoard {
    <# Checks that the hierarchy's work item types exist, and that the story, task and human task types have
       every state their status map names. Tags need no setup. #>
    param([switch]$DryRun)
    $ab = $script:PwConfig.board.azureBoards
    $lines = [System.Collections.Generic.List[string]]::new()
    $levels = Get-PwAbLevels
    $lines.Add("hierarchy: $(@($levels.Values) -join ' > ') (a plan's **Epic:**, **Feature:** or **User Story:** line names the root of its tree)")
    $checked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($level in @($levels.Keys) + 'human') {
        $type = if ($level -eq 'human') { $ab.humanWorkItemType } else { $levels[$level] }
        if (-not $checked.Add($type)) { continue }
        $states = Get-PwAbTypeStates $type
        $names = @($states.Names)
        if (-not $names.Count) { $lines.Add("MISSING: work item type '$type' not found in $($ab.project) ($($states.Error))$(if ($level -eq 'feature') { '; a process without features (Basic) sets featureWorkItemType to ""' })"); continue }
        if ($level -in 'epic', 'feature') { $lines.Add("'$type' found ($level level)"); continue }
        $ownMap = $type -ieq $ab.taskWorkItemType -and $ab.Contains('taskStatusMap') -and $ab.taskStatusMap
        $map = Get-PwAbStatusMap $type
        $mapped = @($script:Statuses | ForEach-Object { $map[$_].state } | Select-Object -Unique)
        $missing = @($mapped | Where-Object { $names -notcontains $_ })
        $fix = if ($ownMap) { 'board.azureBoards.taskStatusMap' } elseif ($type -ieq $ab.taskWorkItemType) { 'board.azureBoards.statusMap, or give the task type its own taskStatusMap' } else { 'board.azureBoards.statusMap' }
        if ($missing.Count) { $lines.Add("MISSING states on '$type': $($missing -join ', ') (it has: $($names -join ', ')). Fix $fix.") }
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
