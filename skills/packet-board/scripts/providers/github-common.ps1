# github-common.ps1: GitHub issue, label, milestone and comment calls shared by the github-project and
# github-issues providers. Dot-sourced after PacketWorkflow.ps1. Reads go over REST (gh api) where they
# can, because every session on an account shares one GraphQL budget an hour.

$script:GhLabelCache = $null
$script:GhMilestoneCache = $null
$script:GhIssueCache = $null
$script:GhDependencyApiWorks = $true

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

function Set-ProvParent {
    <# Makes the item a sub-issue of the phase epic. Already linked is fine. #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][string]$EpicRef)
    $cfg = $script:PwConfig
    $existing = @(Invoke-PwGhPages "repos/$($cfg.repo)/issues/$EpicRef/sub_issues?per_page=100" | ForEach-Object { [long]$_.id })
    if ($existing -contains $Item.DbId) { return $false }
    [void](Invoke-PwGh api -X POST "repos/$($cfg.repo)/issues/$EpicRef/sub_issues" -F "sub_issue_id=$($Item.DbId)")
    $true
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

function Initialize-PwGhLabels {
    <# The labels every GitHub provider uses. Returns the names it created. #>
    param([Parameter(Mandatory)]$Config, [switch]$DryRun)
    $created = [System.Collections.Generic.List[string]]::new()
    $want = @(
        @($Config.labels.packet, '1d76db', 'Managed by the packet workflow'),
        @($Config.labels.human, 'fbca04', 'A task only a person can do'),
        @($Config.labels.needsHuman, 'd93f0b', 'Waiting on a decision from the owner'),
        @($Config.labels.followUp, 'c5def5', 'Found in review; outside the packet that found it')
    )
    foreach ($w in $want) { if (Confirm-PwGhLabel -Config $Config -Name $w[0] -Color $w[1] -Description $w[2] -DryRun:$DryRun) { $created.Add($w[0]) } }
    , $created
}
