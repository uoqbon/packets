# github-common.ps1: GitHub issue, label, milestone and comment calls shared by the github-project and
# github-issues providers. Dot-sourced after PacketWorkflow.ps1. Reads go over REST (gh api) where they
# can, because every session on an account shares one GraphQL budget an hour.

$script:GhLabelCache = $null
$script:GhMilestoneCache = $null
$script:GhIssueCache = $null
$script:GhRemoteIssueCache = @{}
$script:GhDependencyApiWorks = $true
$script:GhLogin = $null

function Invoke-PwGh {
    # Runs gh and returns stdout as one string; throws with stderr on failure. A simple function on
    # purpose: an advanced one would bind -X, -f or -F as its own parameters.
    $GhArgs = @($args)
    $err = [System.IO.Path]::GetTempFileName()
    try {
        $out = & gh @GhArgs 2>$err
        if ($LASTEXITCODE -ne 0) {
            $msg = (Get-Content -Raw -LiteralPath $err)
            Stop-Pw "gh $(($GhArgs | Select-Object -First 4) -join ' ') failed: $(if ($msg) { $msg.Trim() } else { "exit $LASTEXITCODE" })"
        }
        ($out -join "`n")
    }
    finally { Remove-Item -LiteralPath $err -ErrorAction SilentlyContinue }
}

function Invoke-PwGhJson {
    $text = Invoke-PwGh @args
    if (-not $text.Trim()) { return $null }
    $text | ConvertFrom-Json -AsHashtable -Depth 64
}

function Invoke-PwGhPages {
    <# A paginated REST list, flattened into one array. #>
    param([Parameter(Mandatory)][string]$Path)
    $pages = Invoke-PwGhJson api --paginate --slurp $Path
    @(foreach ($page in @($pages)) { foreach ($row in @($page)) { if ($null -ne $row) { $row } } })
}

function Invoke-PwGhWithBodyFile {
    <# gh api call whose body field is read from a temp file, so no shell quoting touches it. #>
    param([Parameter(Mandatory)][string]$Body, [Parameter(Mandatory)][string[]]$GhArgs)
    $file = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($file, $Body, [System.Text.UTF8Encoding]::new($false))
        Invoke-PwGhJson @GhArgs -F "body=@$file"
    }
    finally { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
}

function Get-PwGhPacketId {
    param([string]$Title)
    if ($Title -match "^(?<id>$script:IdPattern)\s*·") { return $Matches.id }
    $null
}

function ConvertTo-PwGhItem {
    <# The parts of a board item every GitHub provider fills the same way, from a REST issue. #>
    param([Parameter(Mandatory)]$Issue, [Parameter(Mandatory)]$Config)
    $labels = @($Issue.labels | ForEach-Object { $_.name })
    $target = $null
    if ($Issue.body -match '\*\*Target:\*\*\s*(?<d>\d{4}-\d{2}-\d{2})') { $target = $Matches.d }
    [pscustomobject]@{
        Id            = Get-PwGhPacketId $Issue.title
        Ref           = [string]$Issue.number
        Number        = [int]$Issue.number
        DbId          = [long]$Issue.id
        NodeId        = $Issue.node_id
        Url           = $Issue.html_url
        Title         = $Issue.title
        Body          = [string]$Issue.body
        Labels        = $labels
        Kind          = if ($labels -contains $Config.labels.human) { 'human' } else { 'packet' }
        Closed        = ($Issue.state -eq 'closed')
        ClosedReason  = $Issue.state_reason
        UpdatedAt     = $Issue.updated_at
        Milestone     = if ($Issue.milestone) { $Issue.milestone.title } else { $null }
        Assignees     = @($Issue.assignees | ForEach-Object { $_.login })
        Status        = $null
        Priority      = $null
        Size          = $null
        Wave          = $null
        Target        = $target
        ProjectItemId = $null
    }
}

function Get-PwGhIssues {
    <# Every issue with the packet label, open or closed, as REST issues (pull requests left out). #>
    param([Parameter(Mandatory)]$Config, [switch]$Refresh)
    if ($script:GhIssueCache -and -not $Refresh) { return $script:GhIssueCache }
    $label = [uri]::EscapeDataString($Config.labels.packet)
    $script:GhIssueCache = @(Invoke-PwGhPages "repos/$($Config.repo)/issues?state=all&labels=$label&per_page=100" |
            Where-Object { -not $_.ContainsKey('pull_request') -or -not $_.pull_request })
    $script:GhIssueCache
}

function Get-PwRemoteItems {
    <# The dependencies among -Ids that are other repositories' packets (the config's remotes, by ID prefix),
       as items keyed by ID for the verdicts. Each repository's packet issues are listed once, over REST, and
       only when such a dependency is asked for. Only issues carrying that repository's packet label are
       seen, as its own kit sees them. One is Done only when such an issue titled "<ID> · …" is closed as
       completed and none is open; otherwise its Reason says why. Their state is all that is read there: no
       comment, status or marker counts, so anyone who can close or label its issues can unblock a
       dependent here. #>
    param([Parameter(Mandatory)]$Config, [string[]]$Ids = @())
    $found = @{}
    foreach ($id in @($Ids | Where-Object { $_ } | Select-Object -Unique)) {
        $repo = Get-PwRemoteRepo -Config $Config -Id $id
        if (-not $repo) { continue }
        $rm = $Config.remotes[($id -split '-')[0]]
        $label = if ($rm.Contains('label')) { [string]$rm.label } else { [string]$Config.labels.packet }
        $key = "$repo $label"
        if (-not $script:GhRemoteIssueCache.ContainsKey($key)) {
            $script:GhRemoteIssueCache[$key] = @(Invoke-PwGhPages "repos/$repo/issues?state=all&labels=$([uri]::EscapeDataString($label))&per_page=100" |
                    Where-Object { -not $_.ContainsKey('pull_request') -or -not $_.pull_request })
        }
        $hits = @($script:GhRemoteIssueCache[$key] | Where-Object { (Get-PwGhPacketId $_.title) -eq $id } | Sort-Object { [int]$_.number })
        $open = @($hits | Where-Object { $_.state -ne 'closed' })
        $completed = @($hits | Where-Object { $_.state -eq 'closed' -and $_.state_reason -eq 'completed' })
        $done = $completed.Count -gt 0 -and $open.Count -eq 0
        $issue = if ($open) { $open[0] } elseif ($completed) { $completed[-1] } elseif ($hits) { $hits[-1] } else { $null }
        $at = if ($issue) { "$repo#$($issue.number)" } else { $repo }
        $status = 'Done'; $reason = ''
        if (-not $done) {
            if ($open) { $status = 'Open'; $reason = "$id is open in $at" }
            elseif ($issue) { $status = 'Closed'; $reason = "$id was closed as $(if ($issue.state_reason) { ([string]$issue.state_reason).Replace('_', ' ') } else { 'not completed' }) in $at" }
            else { $status = 'Not found'; $reason = "$id has no issue in $repo with the label $label" }
        }
        $found[$id] = [pscustomobject]@{
            Id = $id; Remote = $true; Repo = $repo; Done = $done; Status = $status; Reason = $reason
            Ref = if ($issue) { [string]$issue.number } else { $null }; Number = if ($issue) { [int]$issue.number } else { 0 }
            Url = if ($issue) { $issue.html_url } else { $null }; Title = if ($issue) { $issue.title } else { $null }
            Kind = if ($issue -and @($issue.labels | ForEach-Object { $_.name }) -contains $Config.labels.human) { 'human' } else { 'packet' }
            Closed = [bool]($issue -and $issue.state -eq 'closed'); ClosedReason = if ($issue) { $issue.state_reason } else { $null }
            UpdatedAt = if ($issue) { $issue.updated_at } else { $null }
        }
    }
    $found
}

function Get-ProvComments {
    param([Parameter(Mandatory)][string]$Ref)
    @(Invoke-PwGhPages "repos/$($script:PwConfig.repo)/issues/$Ref/comments?per_page=100" | ForEach-Object {
            [pscustomobject]@{ Id = [long]$_.id; CreatedAt = [DateTimeOffset]$_.created_at; Body = [string]$_.body; Author = $_.user.login }
        })
}

function Add-ProvComment {
    param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)][string]$Body)
    $c = Invoke-PwGhWithBodyFile -Body $Body -GhArgs @('api', '-X', 'POST', "repos/$($script:PwConfig.repo)/issues/$Ref/comments")
    [pscustomobject]@{ Id = [long]$c.id; CreatedAt = [DateTimeOffset]$c.created_at; Body = [string]$c.body; Url = $c.html_url }
}

function Remove-ProvComment {
    param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)]$CommentId)
    [void](Invoke-PwGh api -X DELETE "repos/$($script:PwConfig.repo)/issues/comments/$CommentId")
}

function Get-ProvBoardNow {
    <# The latest GitHub's clock can read now, from the Date header of a call to rate_limit (which
       doesn't count against the rate limit), or to user where rate_limit isn't served (GitHub Enterprise
       Server with rate limiting off). #>
    $sent = [DateTimeOffset]::UtcNow
    try { $text = Invoke-PwGh api --include rate_limit }
    catch { $sent = [DateTimeOffset]::UtcNow; $text = Invoke-PwGh api --include user }
    $m = [regex]::Match($text, '(?im)^date:[ \t]*(?<d>[^\r\n]+?)[ \t]*\r?$')
    if (-not $m.Success) { Stop-Pw "GitHub's answer had no Date header, so its clock is unknown" }
    Get-PwBoardNow -Date (ConvertFrom-PwHttpDate $m.Groups['d'].Value) -SentAt $sent
}

$script:GhLogin = $null

function Get-ProvCurrentUser {
    if (-not $script:GhLogin) { $script:GhLogin = (Invoke-PwGh api user --jq .login).Trim() }
    $script:GhLogin
}

function Test-ProvItemComplete {
    <# False when the item exists but lacks something sync must add (github-project: not on the project yet). #>
    param([Parameter(Mandatory)]$Item)
    $true
}

function Get-ProvRefText {
    <# How a PR body refers to the item so merging the PR closes it. #>
    param([Parameter(Mandatory)]$Item)
    "Closes #$($Item.Number)"
}

function Set-ProvAssignee {
    param([Parameter(Mandatory)][string]$Ref)
    [void](Invoke-PwGh issue edit $Ref --repo $script:PwConfig.repo --add-assignee '@me')
}

function Get-PwGhLabels {
    param([Parameter(Mandatory)]$Config)
    if ($null -eq $script:GhLabelCache) {
        $script:GhLabelCache = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($l in (Invoke-PwGhPages "repos/$($Config.repo)/labels?per_page=100")) { [void]$script:GhLabelCache.Add($l.name) }
    }
    # The comma keeps PowerShell from unrolling the set into a fixed-size array on return.
    , $script:GhLabelCache
}

function Confirm-PwGhLabel {
    <# Creates the label if the repo doesn't have it. Never changes an existing label. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Name, [string]$Color = 'ededed', [string]$Description = '', [switch]$DryRun)
    $labels = Get-PwGhLabels $Config
    if ($labels.Contains($Name)) { return $false }
    if (-not $DryRun) {
        [void](Invoke-PwGh api -X POST "repos/$($Config.repo)/labels" -f "name=$Name" -f "color=$Color" -f "description=$Description")
    }
    [void]$labels.Add($Name)
    $true
}

function Confirm-PwGhMilestone {
    <# The milestone number for a phase title, created when missing. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Title, [switch]$DryRun)
    if ($null -eq $script:GhMilestoneCache) {
        $script:GhMilestoneCache = @{}
        foreach ($m in (Invoke-PwGhPages "repos/$($Config.repo)/milestones?state=all&per_page=100")) { $script:GhMilestoneCache[$m.title] = [int]$m.number }
    }
    if ($script:GhMilestoneCache.ContainsKey($Title)) { return $script:GhMilestoneCache[$Title] }
    if ($DryRun) { return 0 }
    $m = Invoke-PwGhJson api -X POST "repos/$($Config.repo)/milestones" -f "title=$Title"
    $script:GhMilestoneCache[$Title] = [int]$m.number
    [int]$m.number
}

function New-PwGhIssue {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Body, [string[]]$Labels = @(), [int]$Milestone = 0)
    $ghArgs = @('api', '-X', 'POST', "repos/$($Config.repo)/issues", '-f', "title=$Title")
    foreach ($l in $Labels) { $ghArgs += @('-f', "labels[]=$l") }
    if ($Milestone -gt 0) { $ghArgs += @('-F', "milestone=$Milestone") }
    $issue = Invoke-PwGhWithBodyFile -Body $Body -GhArgs $ghArgs
    $script:GhIssueCache = $null
    $issue
}

function Update-PwGhIssue {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Body, [int]$Milestone = 0)
    $ghArgs = @('api', '-X', 'PATCH', "repos/$($Config.repo)/issues/$Number", '-f', "title=$Title")
    if ($Milestone -gt 0) { $ghArgs += @('-F', "milestone=$Milestone") }
    [void](Invoke-PwGhWithBodyFile -Body $Body -GhArgs $ghArgs)
    $script:GhIssueCache = $null
}

function Set-PwGhLabels {
    <# Adds Add and removes Remove on one issue; labels it doesn't have are skipped. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][int]$Number, [string[]]$Add = @(), [string[]]$Remove = @(), [string[]]$Current = @())
    $toAdd = @($Add | Where-Object { $_ -and $Current -notcontains $_ })
    if ($toAdd.Count -gt 0) {
        foreach ($l in $toAdd) { [void](Confirm-PwGhLabel -Config $Config -Name $l) }
        $a = @('api', '-X', 'POST', "repos/$($Config.repo)/issues/$Number/labels")
        foreach ($l in $toAdd) { $a += @('-f', "labels[]=$l") }
        [void](Invoke-PwGh @a)
    }
    foreach ($l in ($Remove | Where-Object { $_ -and $Current -contains $_ -and $Add -notcontains $_ })) {
        [void](Invoke-PwGh api -X DELETE "repos/$($Config.repo)/issues/$Number/labels/$([uri]::EscapeDataString($l))")
    }
    $script:GhIssueCache = $null
}

function Resolve-ProvHierarchy {
    <# A phase's tree on GitHub, which has no levels: every packet and human task becomes a sub-issue of the
       plan's root issue (its **Epic:**, **Feature:** or **User Story:** line), except a human task with a
       Parent line, which becomes a sub-issue of that packet's issue. #>
    param([Parameter(Mandatory)]$Phase, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Packets)
    [pscustomobject]@{ Phase = $Phase; Packets = @($Packets) }
}

function Set-ProvHierarchy {
    <# Makes each item of the tree a sub-issue of its place: the root, or the packet a human task's Parent
       line names. Already linked is fine. An issue under another parent (an issue has only one) was put
       there on the board: it is named and left there, and -Force moves it, as on Azure Boards. -DryRun
       reads the same and says what it would link or move, writing nothing; -Creating are the IDs this sync
       creates, which a dry run calls "(new)". #>
    param([Parameter(Mandatory)]$Tree, [Parameter(Mandatory)][hashtable]$ItemsById, [string[]]$Creating = @(), [switch]$DryRun, [switch]$Force)
    $root = $Tree.Phase.Root
    if (-not $root) { return }
    $cfg = $script:PwConfig
    $ref = $root.Ref -replace '^(AB)?#', ''
    $subIssues = @{}
    foreach ($p in $Tree.Packets) {
        $item = $ItemsById[$p.Id]
        $target = $ref; $label = "$($root.Level) #$ref"
        if ($p.Kind -eq 'human' -and $p.Parent) {
            $parentItem = $ItemsById[$p.Parent]
            # A packet with no issue yet is "(new)" only in a dry run of the sync that creates it.
            if ($parentItem) { $target = [string]$parentItem.Number; $label = "$($p.Parent) #$target" }
            elseif ($DryRun -and $Creating -contains $p.Parent) { $target = ''; $label = "$($p.Parent) (new)" }
            else { "note: $(if ($item) { "$($p.Id) #$($item.Number) was left where it is" } else { "$($p.Id) (new) would get no parent" }): its Parent $($p.Parent) isn't on the board"; continue }
        }
        if (-not $item) { if ($DryRun) { "would put $($p.Id) (new) under $label" }; continue }
        if ($target) {
            if (-not $subIssues.ContainsKey($target)) { $subIssues[$target] = @(Invoke-PwGhPages "repos/$($cfg.repo)/issues/$target/sub_issues?per_page=100" | ForEach-Object { [long]$_.id }) }
            if ($subIssues[$target] -contains $item.DbId) { continue }
        }
        # Not under its place: where is it? A 404 is no parent (and a server without this endpoint, where
        # adding fails as it always did if the issue has one).
        $from = $null
        try {
            $parent = Invoke-PwGhJson api "repos/$($cfg.repo)/issues/$($item.Number)/parent"
            $from = if ([string]$parent.repository_url -like "*/repos/$($cfg.repo)") { "#$($parent.number)" } else { "$(([string]$parent.repository_url) -replace '^.*/repos/', '')#$($parent.number)" }
        }
        catch { if ($_.Exception.Message -notmatch 'HTTP 404') { throw } }
        if ($from -and -not $Force) { "note: $($p.Id) #$($item.Number) is under $from, and its place is under ${label}: sync -Phase $($Tree.Phase.Slug) -Force moves it, and also overwrites any body this sync skipped as edited on the board, so first move those edits into the packet files in a pull request, merge it and update this checkout (sync -Phase $($Tree.Phase.Slug) -DryRun -Force shows every change)"; continue }
        if ($DryRun) { "would $(if ($from) { 'move' } else { 'put' }) $($p.Id) #$($item.Number) under $label$(if ($from) { " (now under $from)" })"; continue }
        $replace = @(if ($from) { '-F', 'replace_parent=true' })
        [void](Invoke-PwGh api -X POST "repos/$($cfg.repo)/issues/$target/sub_issues" -F "sub_issue_id=$($item.DbId)" @replace)
        "$(if ($from) { 'moved' } else { 'linked' }) $($p.Id) under $label$(if ($from) { " (was under $from)" })"
    }
}

function Set-ProvDependencies {
    <# Mirrors the packet's Depends on line as GitHub "blocked by" relationships, so the board shows
       them. The packet file stays the source of truth; if the repository doesn't offer the
       dependencies API, this warns once and does nothing. #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$DependencyItems)
    if (-not $script:GhDependencyApiWorks -or @($DependencyItems).Count -eq 0) { return 0 }
    $cfg = $script:PwConfig
    try {
        $existing = @(Invoke-PwGhPages "repos/$($cfg.repo)/issues/$($Item.Number)/dependencies/blocked_by?per_page=100" | ForEach-Object { [long]$_.id })
        $n = 0
        foreach ($d in $DependencyItems) {
            if ($existing -contains $d.DbId) { continue }
            [void](Invoke-PwGh api -X POST "repos/$($cfg.repo)/issues/$($Item.Number)/dependencies/blocked_by" -F "issue_id=$($d.DbId)")
            $n++
        }
        $n
    }
    catch {
        $script:GhDependencyApiWorks = $false
        Write-Warning "GitHub issue dependencies are unavailable here, so 'blocked by' links are skipped (the Depends on line still rules): $($_.Exception.Message)"
        0
    }
}

function Get-PwGhPrForPacket {
    <# The newest pull request whose head branch is pkt/<id>-…, open first. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$PacketId, [string]$State = 'open')
    $prefix = "pkt/$($PacketId.ToLowerInvariant())-"
    $prs = Invoke-PwGhJson pr list --repo $Config.repo --state $State --limit 200 --json 'number,headRefName,baseRefName,url,state,isDraft,headRefOid'
    @($prs | Where-Object { $_.headRefName.StartsWith($prefix) } | Sort-Object { $_.number } -Descending) | Select-Object -First 1
}

function Get-PwGhRounds {
    <# A PR's round reports, settle requests, settle checks and budget raises, oldest first, from trusted authors only:
       the GitHub sign-in and the config's trustedAuthors (PRs are on GitHub, so the GitHub sign-in decides
       even when the board is elsewhere). A settle request is Consumed once a settle check follows it. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Pr)
    if (-not $script:GhLogin) { $script:GhLogin = (Invoke-PwGh api user --jq .login).Trim() }
    $login = $script:GhLogin
    $trusted = [System.Collections.Generic.HashSet[string]]::new([string[]]@(@($login) + @($Config.trustedAuthors | Where-Object { $_ })), [StringComparer]::OrdinalIgnoreCase)
    $last = 0
    $rows = @(Invoke-PwGhPages "repos/$($Config.repo)/issues/$Pr/comments?per_page=100" | Sort-Object { [long]$_.id } | ForEach-Object {
            if (-not $trusted.Contains([string]$_.user.login)) { return }
            $mk = Get-PwMarker $_.body
            if ($mk -and $mk.Kind -eq 'round') {
                $last = [int]($mk.Words | Select-Object -First 1)
                [pscustomobject]@{ Kind = 'round'; Round = $last; Head = $mk.Pairs['head']; Tier = $mk.Pairs['tier']; Lenses = $mk.Pairs['lenses']; Runs = $mk.Pairs['runs']; Confirmed = $mk.Pairs['confirmed']; Outcome = $mk.Pairs['outcome']; Author = $_.user.login; CommentId = $_.id; CreatedAt = $_.created_at; Url = $_.html_url }
            }
            elseif ($mk -and $mk.Kind -eq 'settle') {
                [pscustomobject]@{ Kind = 'settle-request'; Round = $last; Head = $mk.Pairs['head']; Tier = $null; Lenses = $null; Runs = $null; Confirmed = $null; Outcome = 'settle'; Author = $_.user.login; CommentId = $_.id; CreatedAt = $_.created_at; Url = $_.html_url; Body = $_.body }
            }
            elseif ($mk -and $mk.Kind -eq 'settle-check') {
                [pscustomobject]@{ Kind = 'settle-check'; Round = $last; Head = $mk.Pairs['head']; Tier = $null; Lenses = $null; Runs = $null; Confirmed = $null; Outcome = 'settled'; Author = $_.user.login; CommentId = $_.id; CreatedAt = $_.created_at; Url = $_.html_url; Body = $null }
            }
            elseif ($mk -and $mk.Kind -eq 'budget') {
                # A raise of the packet's credit ceiling (credit-check.ps1). Max is as written; the reader checks it.
                [pscustomobject]@{ Kind = 'budget'; Round = $last; Head = $null; Tier = $null; Lenses = $null; Runs = $null; Confirmed = $null; Outcome = 'budget'; Max = $mk.Pairs['max']; Author = $_.user.login; CommentId = $_.id; CreatedAt = $_.created_at; Url = $_.html_url; Body = $null }
            }
        })
    foreach ($r in $rows) {
        $used = $r.Kind -eq 'settle-request' -and [bool]($rows | Where-Object { $_.Kind -eq 'settle-check' -and [long]$_.CommentId -gt [long]$r.CommentId })
        $r | Add-Member -NotePropertyName Consumed -NotePropertyValue $used
    }
    , $rows
}

function Initialize-PwGhLabels {
    <# The labels every GitHub provider uses (or only those named in -Keys). Returns the names it created. #>
    param([Parameter(Mandatory)]$Config, [string[]]$Keys = @('packet', 'human', 'needsHuman', 'followUp'), [switch]$DryRun)
    $created = [System.Collections.Generic.List[string]]::new()
    $want = [ordered]@{
        packet     = @($Config.labels.packet, '1d76db', 'Managed by the packet workflow')
        human      = @($Config.labels.human, 'fbca04', 'A task only a person can do')
        needsHuman = @($Config.labels.needsHuman, 'd93f0b', 'Waiting on a decision from the owner')
        followUp   = @($Config.labels.followUp, 'c5def5', 'Found in review; outside the packet that found it')
    }
    foreach ($k in $want.Keys) {
        if ($Keys -notcontains $k) { continue }
        $w = $want[$k]
        if (Confirm-PwGhLabel -Config $Config -Name $w[0] -Color $w[1] -Description $w[2] -DryRun:$DryRun) { $created.Add($w[0]) }
    }
    , $created
}
