# azure-boards-fake.ps1: an in-memory Azure DevOps for the offline tests. Dot-source it after the
# azure-boards provider: it replaces Invoke-PwAb, the provider's one REST call, with a store that keeps
# work items, their revisions, their states per type and their links. Like Azure DevOps it keeps both
# ends of a link (and gives both a new revision), refuses a second parent, applies a patch only when its
# revision test passes, refuses a state the item's type doesn't have, merges an 'add' on System.Tags into
# the tags already there, and answers a type the project doesn't have with an error. Once a patch makes an
# item's description Markdown, it hands that description back the way the service does, with each " and >
# outside an HTML tag as an entity (&quot;, &gt;: the two seen on the service), not as it was written. It
# keeps work item comments too (list in pages with a continuation token, post, delete), stamped by its own
# clock ($script:FakeAb.Clock, which the tests move and which needn't match the local one), and every
# answer carries that clock as its Date header, in whole seconds. Each comment post and delete is a
# revision of the work item, as on the service. Every call is logged in $script:FakeAbCalls.

$script:FakeAb = @{
    Next   = 1
    Items  = @{}
    States = @{
        'Epic'       = @('New', 'Active', 'Resolved', 'Closed', 'Removed')
        'Feature'    = @('New', 'Active', 'Resolved', 'Closed', 'Removed')
        'User Story' = @('New', 'Active', 'Resolved', 'Closed', 'Removed')
        'Task'       = @('New', 'Active', 'Closed', 'Removed')
        'Issue'      = @('To Do', 'Doing', 'Done')
        'Approval'   = @('New', 'Active', 'Resolved', 'Closed')
    }
    # Comments by work item id. Deleted ones stay, marked isDeleted, and are listed like that (as with
    # includeDeleted), so the provider's filter is what hides them.
    Comments    = @{}
    NextComment = 1
    CommentPage = 200
    Clock       = [DateTimeOffset]'2026-10-22T20:00:00Z'
    User        = 'dispatcher@example.com'
    # Run after each comment is posted, before the answer goes back: a competitor racing in.
    OnComment   = $null
}
$script:FakeAbCalls = [System.Collections.Generic.List[string]]::new()
$script:FakeAbBack = @{
    'System.LinkTypes.Hierarchy-Reverse' = 'System.LinkTypes.Hierarchy-Forward'
    'System.LinkTypes.Hierarchy-Forward' = 'System.LinkTypes.Hierarchy-Reverse'
    'System.LinkTypes.Dependency-Reverse' = 'System.LinkTypes.Dependency-Forward'
    'System.LinkTypes.Dependency-Forward' = 'System.LinkTypes.Dependency-Reverse'
}

function Stop-FakeAb { param([string]$Method, [string]$Path, [string]$Why) Stop-Pw "Azure DevOps $Method $Path failed: $Why" }

function Get-FakeAbTarget { param($Relation) [int](($Relation.url -split '/')[-1]) }

function Add-FakeAbLink {
    param([int]$From, [string]$Rel, [int]$To)
    $item = $script:FakeAb.Items[$From]; $other = $script:FakeAb.Items[$To]
    if (-not $other) { throw "TF401232: work item $To does not exist" }
    if ($Rel -eq 'System.LinkTypes.Hierarchy-Reverse' -and @($item.relations | Where-Object { $_.rel -eq $Rel }).Count) { throw "TF201036: work item $From already has a parent" }
    $item.relations.Add(@{ rel = $Rel; url = "https://dev.azure.com/fake/_apis/wit/workItems/$To"; attributes = @{} })
    $back = $script:FakeAbBack[$Rel]
    if ($back) { $other.relations.Add(@{ rel = $back; url = "https://dev.azure.com/fake/_apis/wit/workItems/$From"; attributes = @{} }); $other.rev++ }
}

function Remove-FakeAbLink {
    param([int]$From, [int]$Index)
    $item = $script:FakeAb.Items[$From]
    if ($Index -ge $item.relations.Count) { throw "no relation at index $Index of work item $From" }
    $r = $item.relations[$Index]
    $item.relations.RemoveAt($Index)
    $other = $script:FakeAb.Items[(Get-FakeAbTarget $r)]
    $back = $script:FakeAbBack[$r.rel]
    if ($other -and $back) {
        $i = $other.relations.FindIndex([Predicate[object]] { param($x) $x.rel -eq $back -and (Get-FakeAbTarget $x) -eq $From })
        if ($i -ge 0) { $other.relations.RemoveAt($i); $other.rev++ }
    }
}

function Join-FakeAbTags {
    <# Azure DevOps's 'add' on System.Tags: the tags already there, plus the new ones (tags ignore case).
       Only 'replace' sets the list. #>
    param([string]$Old, [string]$New)
    $tags = [System.Collections.Generic.List[string]]::new()
    foreach ($t in @("$Old" -split ';') + @("$New" -split ';')) {
        $t = $t.Trim()
        if ($t -and -not ($tags | Where-Object { $_ -ieq $t })) { $tags.Add($t) }
    }
    $tags -join '; '
}

function New-FakeAbItem {
    <# A work item made by the test, as someone made it on the board. #>
    param([Parameter(Mandatory)][string]$Type, [string]$Title = '', [string]$Tags = '', [string]$State = '', [int]$Parent = 0)
    $id = $script:FakeAb.Next++
    $script:FakeAb.Items[$id] = @{
        id = $id; rev = 1; relations = [System.Collections.Generic.List[object]]::new()
        fields = @{ 'System.Id' = $id; 'System.WorkItemType' = $Type; 'System.Title' = $Title; 'System.State' = $(if ($State) { $State } else { $script:FakeAb.States[$Type][0] }); 'System.Tags' = $Tags }
    }
    if ($Parent) { Add-FakeAbLink $id 'System.LinkTypes.Hierarchy-Reverse' $Parent }
    $id
}

function Copy-FakeAbItem {
    param($Item, [switch]$Relations)
    $copy = @{ id = $Item.id; rev = $Item.rev; fields = @{} + $Item.fields }
    if ($Relations -and $Item.relations.Count) { $copy.relations = @($Item.relations | ForEach-Object { @{} + $_ }) }
    $copy
}

function Set-FakeAbOps {
    <# A JSON patch, all or nothing: on a failed test or a refused op the item is left as it was. #>
    param([string]$Method, [string]$Path, [int]$Id, $Ops)
    $item = $script:FakeAb.Items[$Id]
    $saved = @{ fields = @{} + $item.fields; relations = @($item.relations) }
    $others = @{}; foreach ($o in $script:FakeAb.Items.Values) { if ($o.id -ne $Id) { $others[$o.id] = @{ relations = @($o.relations); rev = $o.rev } } }
    $markdown = [bool]$item['markdown']; $described = $false
    try {
        foreach ($op in @($Ops)) {
            if ($op.op -eq 'test' -and $op.path -eq '/rev') { if ([int]$op.value -ne $item.rev) { throw "TF26071: revision $($op.value) is out of date (now $($item.rev))" }; continue }
            if ($op.path -eq '/multilineFieldsFormat/System.Description') { $markdown = $op.value -eq 'Markdown'; continue }
            if ($op.path -match '^/multilineFieldsFormat/') { continue }
            if ($op.path -match '^/fields/(?<f>.+)$') {
                $field = $Matches.f
                if ($field -eq 'System.State' -and $script:FakeAb.States[$item.fields['System.WorkItemType']] -notcontains $op.value) { throw "TF401320: '$($op.value)' is not a state of $($item.fields['System.WorkItemType'])" }
                if ($field -eq 'System.Tags' -and $op.op -eq 'add') { $item.fields[$field] = Join-FakeAbTags $item.fields[$field] $op.value; continue }
                if ($field -eq 'System.Description') { $described = $true }
                $item.fields[$field] = $op.value; continue
            }
            if ($op.op -eq 'add' -and $op.path -eq '/relations/-') { Add-FakeAbLink $Id $op.value.rel (Get-FakeAbTarget $op.value); continue }
            if ($op.op -eq 'remove' -and $op.path -match '^/relations/(?<i>\d+)$') { Remove-FakeAbLink $Id ([int]$Matches.i); continue }
            throw "the fake has no op $($op.op) $($op.path)"
        }
    }
    catch {
        $item.fields = $saved.fields; $item.relations = [System.Collections.Generic.List[object]]::new([object[]]$saved.relations)
        foreach ($k in $others.Keys) { $script:FakeAb.Items[$k].relations = [System.Collections.Generic.List[object]]::new([object[]]$others[$k].relations); $script:FakeAb.Items[$k].rev = $others[$k].rev }
        Stop-FakeAb $Method $Path $_.Exception.Message
    }
    $item.markdown = $markdown
    if ($markdown -and $described) {
        $item.fields['System.Description'] = [regex]::Replace([string]$item.fields['System.Description'], '</?[A-Za-z][^<>]*>|"|>', { param($m) switch ($m.Value) { '"' { '&quot;' } '>' { '&gt;' } default { $m.Value } } })
    }
    $item.rev++
}

function Add-FakeAbComment {
    <# A comment on a work item, stamped by the fake's clock (or -At), as -By posted it. #>
    param([Parameter(Mandatory)][int]$Id, [Parameter(Mandatory)][string]$Text, [string]$By = $script:FakeAb.User, $At = $null)
    if (-not $script:FakeAb.Items.ContainsKey($Id)) { throw "TF401232: work item $Id does not exist" }
    if (-not $script:FakeAb.Comments.ContainsKey($Id)) { $script:FakeAb.Comments[$Id] = [System.Collections.Generic.List[object]]::new() }
    $c = @{ id = $script:FakeAb.NextComment++; workItemId = $Id; text = $Text; createdDate = $(if ($At) { [DateTimeOffset]$At } else { $script:FakeAb.Clock }).ToString('o'); createdBy = @{ uniqueName = $By }; isDeleted = $false }
    $script:FakeAb.Comments[$Id].Add($c)
    $script:FakeAb.Items[$Id].rev++
    $c
}

function Move-FakeAbClock {
    param([double]$Minutes = 0, [double]$Seconds = 0)
    $script:FakeAb.Clock = $script:FakeAb.Clock.AddMinutes($Minutes).AddSeconds($Seconds)
}

function Get-FakeAbComments {
    <# A work item's comments that aren't deleted, oldest first. #>
    param([int]$Id)
    @($script:FakeAb.Comments[$Id] | Where-Object { $_ -and -not $_.isDeleted })
}

function Invoke-PwAb {
    param(
        [string]$Method = 'GET', [Parameter(Mandatory)][string]$Path, $Body,
        [string]$ContentType = 'application/json', [string]$ApiVersion = '7.1', [switch]$OrgLevel
    )
    $script:FakeAbCalls.Add("$Method $Path")
    $clock = $script:FakeAb.Clock
    $script:AbServerClock = @{ Date = [DateTimeOffset]::new($clock.UtcTicks - $clock.UtcTicks % [TimeSpan]::TicksPerSecond, [TimeSpan]::Zero); SentAt = [DateTimeOffset]::UtcNow }
    if ($Method -eq 'GET' -and $Path -eq '_apis/connectionData' -and $OrgLevel) {
        return @{ authenticatedUser = @{ properties = @{ Account = @{ '$value' = $script:FakeAb.User } } } }
    }
    if ($Path -match '^_apis/wit/workItems/(?<id>\d+)/comments(?:/(?<cid>\d+))?(?:\?(?<q>.*))?$') {
        $id = [int]$Matches.id; $cid = $Matches['cid']; $q = "$($Matches['q'])"
        if (-not $script:FakeAb.Items.ContainsKey($id)) { Stop-FakeAb $Method $Path "TF401232: work item $id does not exist" }
        $list = @($script:FakeAb.Comments[$id] | Where-Object { $_ })
        if ($Method -eq 'GET' -and -not $cid) {
            # Newest first, as the service lists them; the continuation token is where the next page starts.
            $top = if ($q -match '(?:^|&)\$top=(?<n>\d+)') { [Math]::Min([int]$Matches.n, $script:FakeAb.CommentPage) } else { $script:FakeAb.CommentPage }
            $start = if ($q -match '(?:^|&)continuationToken=(?<t>[^&]+)') { [int][uri]::UnescapeDataString($Matches.t) } else { 0 }
            [array]::Reverse($list)
            $page = @($list | Select-Object -Skip $start -First $top)
            $r = @{ totalCount = $list.Count; count = $page.Count; comments = @($page | ForEach-Object { @{} + $_ }) }
            if ($start + $top -lt $list.Count) { $r.continuationToken = [string]($start + $top) }
            return $r
        }
        if ($Method -eq 'POST' -and -not $cid) {
            $c = Add-FakeAbComment -Id $id -Text $Body.text
            if ($script:FakeAb.OnComment) { $hook = $script:FakeAb.OnComment; $script:FakeAb.OnComment = $null; & $hook $c }
            return (@{} + $c)
        }
        if ($Method -eq 'DELETE' -and $cid) {
            $c = $list | Where-Object { $_.id -eq [int]$cid -and -not $_.isDeleted } | Select-Object -First 1
            if (-not $c) { Stop-FakeAb $Method $Path "TF401181: comment $cid does not exist" }
            $c.isDeleted = $true
            $script:FakeAb.Items[$id].rev++
            return $null
        }
    }
    if ($Method -eq 'GET' -and $Path -match '^_apis/wit/workitems/(?<id>\d+)\?(?<q>.*)$') {
        $id = [int]$Matches.id; $expand = $Matches.q -match 'expand=relations'
        if (-not $script:FakeAb.Items.ContainsKey($id)) { Stop-FakeAb $Method $Path "TF401232: work item $id does not exist" }
        return (Copy-FakeAbItem $script:FakeAb.Items[$id] -Relations:$expand)
    }
    if ($Method -eq 'POST' -and $Path -eq '_apis/wit/wiql') {
        $tag = if ($Body.query -match "CONTAINS '(?<t>[^']+)'") { $Matches.t } else { '' }
        $ids = @($script:FakeAb.Items.Keys | Sort-Object | Where-Object { @(([string]$script:FakeAb.Items[$_].fields['System.Tags']) -split ';' | ForEach-Object { $_.Trim() }) -contains $tag })
        return @{ workItems = @($ids | ForEach-Object { @{ id = $_ } }) }
    }
    if ($Method -eq 'POST' -and $Path -eq '_apis/wit/workitemsbatch') {
        return @{ value = @(foreach ($id in $Body.ids) { if ($script:FakeAb.Items.ContainsKey([int]$id)) { Copy-FakeAbItem $script:FakeAb.Items[[int]$id] } else { $null } }) }
    }
    if ($Method -eq 'POST' -and $Path -match '^_apis/wit/workitems/\$(?<type>.+)$') {
        $type = [uri]::UnescapeDataString($Matches.type)
        if (-not $script:FakeAb.States.ContainsKey($type)) { Stop-FakeAb $Method $Path "TF401326: no work item type '$type'" }
        $id = New-FakeAbItem -Type $type
        $script:FakeAb.Items[$id].rev = 0
        Set-FakeAbOps $Method $Path $id $Body
        return (Copy-FakeAbItem $script:FakeAb.Items[$id])
    }
    if ($Method -eq 'PATCH' -and $Path -match '^_apis/wit/workitems/(?<id>\d+)$') {
        $id = [int]$Matches.id
        if (-not $script:FakeAb.Items.ContainsKey($id)) { Stop-FakeAb $Method $Path "TF401232: work item $id does not exist" }
        Set-FakeAbOps $Method $Path $id $Body
        return (Copy-FakeAbItem $script:FakeAb.Items[$id])
    }
    if ($Method -eq 'GET' -and $Path -match '^_apis/wit/workitemtypes/(?<type>[^/]+)/states$') {
        $type = [uri]::UnescapeDataString($Matches.type)
        if (-not $script:FakeAb.States.ContainsKey($type)) { Stop-FakeAb $Method $Path "TF51535: cannot find work item type '$type'" }
        return @{ value = @($script:FakeAb.States[$type] | ForEach-Object { @{ name = $_ } }) }
    }
    Stop-FakeAb $Method $Path 'the fake has no such route'
}

function Get-FakeAbWrites {
    <# The calls that changed the store, from the log entry at -Since on. #>
    param([int]$Since = 0)
    @($script:FakeAbCalls | Select-Object -Skip $Since | Where-Object { $_ -match '^(PATCH|POST _apis/wit/workitems/)' })
}

function Get-FakeAbParent {
    <# The parent of a work item, named the way the tests read it: a packet by its ID, anything else by its
       title; "none", or "N parents" when Azure DevOps would never allow it. #>
    param([int]$Id)
    $ups = @($script:FakeAb.Items[$Id].relations | Where-Object { $_.rel -eq 'System.LinkTypes.Hierarchy-Reverse' })
    if ($ups.Count -eq 0) { return 'none' }
    if ($ups.Count -gt 1) { return "$($ups.Count) parents" }
    $title = [string]$script:FakeAb.Items[(Get-FakeAbTarget $ups[0])].fields['System.Title']
    if ($title -match '^(?<id>[A-Z][A-Z0-9]*-\d+)\s*·') { $Matches.id } else { $title }
}

function Find-FakeAbItem {
    <# The id of the work item whose title starts with -Title (a packet ID, or a whole title). #>
    param([string]$Title)
    $script:FakeAb.Items.Values | Where-Object { [string]$_.fields['System.Title'] -eq $Title -or ([string]$_.fields['System.Title']).StartsWith("$Title ·") } | ForEach-Object { $_.id } | Sort-Object | Select-Object -First 1
}
