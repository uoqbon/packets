#Requires -Version 7.2
# PacketWorkflow.ps1: shared logic for the packet workflow kit, dot-sourced by every script. It reads
# the config and the packet files, matches paths against packet globs, walks the dependency graph,
# decides verdicts and runs the claim check. The board providers (providers/*.ps1, dot-sourced next to this file by board.ps1 and
# progress.ps1) supply the item and comment primitives (*-Prov* functions) the claim check calls; this
# file never talks to a board itself. Dot-source it at script level: . "$PSScriptRoot/PacketWorkflow.ps1".

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
# Native commands (git, gh, az) print UTF-8; read it as such on every platform, or a '·' in a title is lost.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$script:Statuses = @('Backlog', 'Ready', 'In progress', 'In review', 'Ready to merge', 'Needs human', 'Done')
$script:IdPattern = '[A-Z][A-Z0-9]*-\d+'

$script:Defaults = @{
    version       = 1
    defaultBranch = 'main'
    packetPrefix  = 'PKT'
    humanPrefix   = 'H'
    paths         = @{ plans = 'docs/plan'; decisions = 'docs/decisions/{phase}/{packet}.md'; lenses = '.github/packet-lenses' }
    board         = @{
        provider     = 'github-issues'
        githubProject = @{ owner = '@me'; number = 0; fields = @{ status = 'Status'; priority = 'Priority'; size = 'Size'; wave = 'Wave'; packet = 'Packet'; target = 'Target date' } }
        githubIssues  = @{ statusPrefix = 'status:'; priorityPrefix = 'priority:'; sizePrefix = 'size:'; wavePrefix = 'wave:' }
        # The work item types of the hierarchy, top down: epic, feature ('' where the process has none),
        # story (workItemType) and task. statusMap is for stories; taskStatusMap, when set, for tasks.
        azureBoards   = @{ epicWorkItemType = 'Epic'; featureWorkItemType = 'Feature'; workItemType = 'User Story'; taskWorkItemType = 'Task'; humanWorkItemType = 'Task'; areaPath = ''; iterationPath = ''; doneStates = @('Closed', 'Removed'); priorityField = 'Microsoft.VSTS.Common.Priority'; targetDateField = ''; markdown = $true }
    }
    labels        = @{ packet = 'packet'; human = 'human-task'; needsHuman = 'needs-human'; followUp = 'follow-up' }
    commands      = @{ test = ''; ci = '' }
    guardrails    = @{ protectedBranches = @('main'); forbiddenCommands = @(); rules = @() }
    locks         = @()
    stacking      = $false
    trustedAuthors = @()
    # Other repositories' packets this repository's packets may depend on, by ID prefix:
    # @{ API = @{ repo = 'acme/api'; label = 'packet' } } (label: that repository's packet label, default labels.packet).
    remotes       = @{}
    claims        = @{ leaseMinutes = 30 }
    review        = @{
        maxRounds = 3; maxParallelLenses = 2; lensesPerReviewer = 1
        # shouldFixPassFromRound defaults to maxRounds (Get-PwConfig): only the last round passes on should-fix findings.
        agents = @{ '1' = 'packet-reviewer-light'; '2' = 'packet-reviewer-standard'; '3' = 'packet-reviewer-deep' }
        maxPaths = ''; deepPaths = ''; lensPaths = @{}; concurrencyPattern = ''
        lensOrder = @('security', 'data', 'concurrency', 'ai', 'integration', 'ops', 'architecture', 'correctness', 'ux', 'performance', 'tests')
    }
    sizes         = @{ S = 1; M = 2; L = 3 }
    # Credits per run on GitHub Copilot's usage-based billing (docs/cost.md), for progress.ps1 -Credits.
    # Estimates to calibrate against the AI usage report; monthlyCredits 0 means no allowance is set.
    budget        = @{
        monthlyCredits = 0
        creditsPerRun  = @{
            dispatcher = 50; dispatcherPerRound = @{ S = 300; M = 330; L = 390 }; dispatcherPerReviewerRun = 35
            implementer = @{ S = 105; M = 200; L = 355 }
            implementerFix = @{ S = 40; M = 55; L = 75 }
            reviewerByTier = @{ S = @(20, 50, 195); M = @(30, 70, 280); L = @(40, 95, 380) }
            laterRoundFactor = 0.85
        }
    }
}

class PwError : System.Exception {
    PwError([string]$Message) : base($Message) {}
}

function Stop-Pw {
    param([Parameter(Mandatory)][string]$Message)
    throw [PwError]::new($Message)
}

function Get-PwStatuses { , $script:Statuses }

function Merge-PwHashtable {
    param([System.Collections.IDictionary]$Base, [System.Collections.IDictionary]$Over)
    $result = @{}
    foreach ($k in $Base.Keys) { $result[$k] = $Base[$k] }
    foreach ($k in $Over.Keys) {
        if ($result[$k] -is [System.Collections.IDictionary] -and $Over[$k] -is [System.Collections.IDictionary]) {
            $result[$k] = Merge-PwHashtable $result[$k] $Over[$k]
        }
        else { $result[$k] = $Over[$k] }
    }
    $result
}

function Get-RepoRoot {
    $root = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $root) { Stop-Pw 'not inside a git repository' }
    ($root | Select-Object -First 1).Trim()
}

function Test-PwRegex {
    param([string]$Name, [string]$Pattern)
    if (-not $Pattern) { return }
    try { [void][regex]::new($Pattern) }
    catch { Stop-Pw "config: $Name is not a valid regular expression: $Pattern" }
}

function Get-PwConfig {
    <# Reads .github/packet-workflow.json (or -Path), fills defaults and validates it. A config that
       can't be read or names an invalid regex stops the caller: a review raise that silently
       disappears would lower a tier. #>
    param([string]$Path, [string]$Ref)
    # -Ref reads the config as committed at that commit (scripts that judge a packet branch pass its
    # base, so the branch can't loosen its own checks). It falls back to the working tree, with a
    # warning, only when the commit has no config at all (the PR that installs the kit).
    $root = Get-RepoRoot
    $text = $null
    if (-not $Path -and $Ref) {
        $raw = & git -C $root show "${Ref}:.github/packet-workflow.json" 2>$null
        if ($LASTEXITCODE -eq 0) { $text = $raw -join "`n"; $Path = "${Ref}:.github/packet-workflow.json" }
        else { Write-Warning "no .github/packet-workflow.json at $Ref; using the working tree's" }
    }
    if (-not $text) {
        if (-not $Path) { $Path = Join-Path $root '.github/packet-workflow.json' }
        if (-not (Test-Path -LiteralPath $Path)) {
            Stop-Pw "no config at ${Path}: run the kit's install.ps1, or copy templates/packet-workflow.json there and fill it in"
        }
        $text = Get-Content -Raw -LiteralPath $Path
    }
    try { $user = $text | ConvertFrom-Json -AsHashtable }
    catch { Stop-Pw "config $Path is not valid JSON: $($_.Exception.Message)" }
    $cfg = Merge-PwHashtable $script:Defaults $user
    $cfg.repoRoot = $root
    $cfg.configPath = $Path

    if (-not $cfg.repo -or $cfg.repo -notmatch '^[\w.-]+/[\w.-]+$' -or $cfg.repo -eq 'OWNER/REPO') {
        Stop-Pw "config: repo must be the GitHub repository as owner/name (got '$($cfg.repo)')"
    }
    foreach ($key in 'packetPrefix', 'humanPrefix') {
        if ($cfg[$key] -notmatch '^[A-Z][A-Z0-9]*$') { Stop-Pw "config: $key must be upper-case letters and digits (got '$($cfg[$key])')" }
    }
    if ($cfg.packetPrefix -eq $cfg.humanPrefix) { Stop-Pw 'config: packetPrefix and humanPrefix must differ' }
    switch ($cfg.board.provider) {
        'github-project' {
            $gp = $cfg.board.githubProject
            if (-not $gp.owner -or [int]$gp.number -le 0) { Stop-Pw 'config: board.githubProject needs owner and number' }
        }
        'github-issues' { }
        'local' { }
        'azure-boards' {
            $ab = $cfg.board.azureBoards
            if (-not $ab.organization -or $ab.organization -notmatch '^https://' -or $ab.organization -match '/ORG$') { Stop-Pw 'config: board.azureBoards.organization must be the organization URL, such as https://dev.azure.com/contoso' }
            if (-not $ab.project -or $ab.project -eq 'PROJECT') { Stop-Pw 'config: board.azureBoards.project is required' }
            foreach ($mapName in @('statusMap') + @(if ($ab.Contains('taskStatusMap') -and $null -ne $ab.taskStatusMap) { 'taskStatusMap' })) {
                foreach ($s in $script:Statuses) {
                    if (-not $ab[$mapName] -or -not $ab[$mapName][$s] -or -not $ab[$mapName][$s]['state']) { Stop-Pw "config: board.azureBoards.$mapName needs a state for '$s'" }
                }
            }
            foreach ($key in 'epicWorkItemType', 'workItemType', 'taskWorkItemType', 'humanWorkItemType') {
                if (-not $ab[$key] -or $ab[$key] -isnot [string]) { Stop-Pw "config: board.azureBoards.$key must name a work item type" }
            }
            if ($ab.featureWorkItemType -and $ab.featureWorkItemType -isnot [string]) { Stop-Pw 'config: board.azureBoards.featureWorkItemType must name a work item type, or be "" where the process has no features' }
        }
        default { Stop-Pw "config: board.provider must be github-project, github-issues, azure-boards or local (got '$($cfg.board.provider)')" }
    }
    Test-PwRegex 'review.maxPaths' $cfg.review.maxPaths
    Test-PwRegex 'review.deepPaths' $cfg.review.deepPaths
    Test-PwRegex 'review.concurrencyPattern' $cfg.review.concurrencyPattern
    foreach ($lens in @($cfg.review.lensPaths.Keys)) { Test-PwRegex "review.lensPaths.$lens" $cfg.review.lensPaths[$lens] }
    foreach ($lock in @($cfg.locks)) {
        if (-not $lock.name -or -not $lock.paths) { Stop-Pw 'config: every entry in locks needs a name and paths' }
    }
    # remotes: a dependency whose ID prefix is listed here is a packet of that repository (Get-PwRemoteItems).
    if ($null -eq $cfg.remotes) { $cfg.remotes = @{} }
    if ($cfg.remotes -isnot [System.Collections.IDictionary]) { Stop-Pw 'config: remotes must map packet ID prefixes to { "repo": "owner/name" }' }
    # remotes as written: the merge above folds case, so a "Remotes" block, or an "api" key beside "API",
    # would replace what a reader of the file sees, unchecked.
    $rawNames = @(if ($user -is [System.Collections.IDictionary]) { $user.Keys | Where-Object { $_ -eq 'remotes' } })
    if ($rawNames.Count -gt 1 -or ($rawNames.Count -eq 1 -and $rawNames[0] -cne 'remotes')) { Stop-Pw "config: write remotes once, in lower case (found $($rawNames -join ', '))" }
    $rawRemotes = if ($rawNames.Count) { $user['remotes'] } else { $null }
    if ($rawRemotes -is [System.Collections.IDictionary]) {
        foreach ($prefix in @($rawRemotes.Keys)) {
            if ($prefix -cnotmatch '^[A-Z][A-Z0-9]*$') { Stop-Pw "config: remotes key '$prefix' must be a packet ID prefix: upper-case letters and digits" }
        }
    }
    foreach ($prefix in @($cfg.remotes.Keys)) {
        $rm = $cfg.remotes[$prefix]
        if ($prefix -eq $cfg.packetPrefix -or $prefix -eq $cfg.humanPrefix) { Stop-Pw "config: remotes.$prefix is this repository's own prefix" }
        if ($rm -isnot [System.Collections.IDictionary] -or $rm.repo -isnot [string] -or $rm.repo -notmatch '^[\w.-]+/[\w.-]+$') { Stop-Pw "config: remotes.$prefix.repo must be the other GitHub repository as owner/name" }
        if ($rm.repo -eq $cfg.repo) { Stop-Pw "config: remotes.$prefix names this repository ($($cfg.repo)); its own packets need no remote" }
        if ($rm.Contains('label') -and ($rm.label -isnot [string] -or -not $rm.label.Trim())) { Stop-Pw "config: remotes.$prefix.label must be that repository's packet label" }
    }
    if ([int]$cfg.claims.leaseMinutes -lt 5) { Stop-Pw 'config: claims.leaseMinutes must be at least 5' }
    # The review limits, as whole numbers (a quoted "3" still counts). The table is copied first: without a
    # review block in the config it is the defaults' own, which a second config in this process would inherit.
    $rv = Merge-PwHashtable $cfg.review @{}
    $cfg.review = $rv
    $whole = { param($v) if ($v -is [int] -or $v -is [long]) { [int]$v } elseif ($v -is [double] -and $v -ge 0 -and $v -le 1000 -and $v -eq [Math]::Floor($v)) { [int]$v } elseif ($v -is [string] -and $v -match '^\s*\d{1,4}\s*$') { [int]$v.Trim() } else { $null } }
    foreach ($key in 'maxRounds', 'maxParallelLenses', 'lensesPerReviewer') {
        $n = & $whole $rv[$key]
        if ($null -eq $n) { Stop-Pw "config: review.$key must be a whole number (got '$($rv[$key])')" }
        $rv[$key] = $n
    }
    if ($rv.maxRounds -lt 1 -or $rv.maxParallelLenses -lt 1) { Stop-Pw 'config: review.maxRounds and review.maxParallelLenses must be at least 1' }
    if ($rv.lensesPerReviewer -lt 1 -or $rv.lensesPerReviewer -gt 3) { Stop-Pw "config: review.lensesPerReviewer must be 1, 2 or 3 (got $($rv.lensesPerReviewer))" }
    # From this round on, a round whose confirmed findings are all should-fix passes with follow-ups.
    # Unset, or past maxRounds, it is the last round: the rule before this setting existed.
    if (-not $rv.Contains('shouldFixPassFromRound') -or $null -eq $rv.shouldFixPassFromRound) { $rv.shouldFixPassFromRound = $rv.maxRounds }
    else {
        $n = & $whole $rv.shouldFixPassFromRound
        if ($null -eq $n -or $n -lt 1) { Stop-Pw "config: review.shouldFixPassFromRound must be a round number, 1 or more (got '$($rv.shouldFixPassFromRound)')" }
        $rv.shouldFixPassFromRound = [Math]::Min($n, $rv.maxRounds)
    }
    # budget is checked where it is used (Get-PwCreditEstimate): a typo there must not stop the board.
    $cfg
}

function Get-PwDefaultRemoteRef {
    <# origin's default branch as the remote reports it (refs/remotes/origin/HEAD), never as a checked-out
       file says, so a branch can't point the kit at a config of its choosing. $null without an origin. #>
    $root = Get-RepoRoot
    if (@(& git -C $root remote 2>$null) -notcontains 'origin') { return $null }
    $ref = & git -C $root symbolic-ref -q --short refs/remotes/origin/HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $ref) { Stop-Pw "origin's default branch isn't known in this clone: run git remote set-head origin --auto" }
    ($ref | Select-Object -First 1).Trim()
}

function Get-PwSharedConfig {
    <# The config that board.ps1 and progress.ps1 use: as merged on origin's default branch, so a branch
       checked out here can't change who is trusted, which board is written or anything else shared. The
       working tree isn't read at all. -Path overrides; a repository without an origin uses its working
       tree; one whose default branch has no config yet (the PR that installs the kit) falls back to the
       working tree with a warning. A config change takes effect once it merges. #>
    param([string]$Path)
    if ($Path) { return Get-PwConfig -Path $Path }
    $ref = Get-PwDefaultRemoteRef
    if (-not $ref) { return Get-PwConfig }
    $cfg = Get-PwConfig -Ref $ref
    $branch = $ref -replace '^origin/', ''
    if ($cfg.defaultBranch -ne $branch) {
        Write-Warning "config says defaultBranch '$($cfg.defaultBranch)' but origin's default branch is '$branch'; using '$branch'"
        $cfg.defaultBranch = $branch
    }
    $cfg
}

function ConvertTo-PwRepoPath {
    <# A configured repo-relative path in the form git prints: forward slashes, no ./, no leading or trailing /. #>
    param([string]$Path)
    $p = ([string]$Path).Trim().Replace('\', '/')
    while ($p.StartsWith('./')) { $p = $p.Substring(2) }
    $p.Trim('/')
}

# ---------------------------------------------------------------------------------------------------
# Globs. Packet paths are repo-relative globs with forward slashes: * stays inside one segment,
# ** spans segments, ? is one character. A path without wildcards names a file or a whole directory.
# A leading ! in an Owns entry excludes what it matches.

function ConvertTo-PwGlobRegex {
    param([Parameter(Mandatory)][string]$Glob)
    $g = $Glob.Trim().Replace('\', '/')
    if ($g.StartsWith('./')) { $g = $g.Substring(2) }
    if ($g.StartsWith('/')) { $g = $g.Substring(1) }
    if ($g -notmatch '[*?]') {
        $plain = [regex]::Escape($g.TrimEnd('/'))
        return "^$plain(?:/.*)?$"
    }
    $sb = [System.Text.StringBuilder]::new('^')
    $i = 0
    while ($i -lt $g.Length) {
        $c = $g[$i]
        if ($c -eq '*') {
            if ($i + 1 -lt $g.Length -and $g[$i + 1] -eq '*') {
                if ($i + 2 -lt $g.Length -and $g[$i + 2] -eq '/') { [void]$sb.Append('(?:.*/)?'); $i += 3; continue }
                [void]$sb.Append('.*'); $i += 2; continue
            }
            [void]$sb.Append('[^/]*')
        }
        elseif ($c -eq '?') { [void]$sb.Append('[^/]') }
        else { [void]$sb.Append([regex]::Escape([string]$c)) }
        $i++
    }
    if ($g.EndsWith('/')) { [void]$sb.Append('.*') }
    [void]$sb.Append('$')
    $sb.ToString()
}

function Test-PwGlob {
    param([string]$Path, [string[]]$Globs)
    foreach ($glob in $Globs) {
        if ($Path -match (ConvertTo-PwGlobRegex $glob)) { return $true }
    }
    $false
}

function Get-PwGlobPrefix {
    # The literal part of a glob before its first wildcard: what any path it matches starts with.
    param([string]$Glob)
    $g = $Glob.Trim().TrimStart('!').Replace('\', '/')
    if ($g.StartsWith('./')) { $g = $g.Substring(2) }
    $idx = $g.IndexOfAny([char[]]'*?')
    if ($idx -lt 0) { return $g.TrimEnd('/') }
    $g.Substring(0, $idx)
}

function Test-PwPacketOwnsPath {
    # True when the packet's Owns (minus its exclusions) or one of its shared touchpoints covers Path.
    param($Packet, [string]$Path, [switch]$OwnsOnly)
    $owned = (Test-PwGlob $Path $Packet.Owns) -and -not (Test-PwGlob $Path $Packet.Excludes)
    if ($owned -or $OwnsOnly) { return $owned }
    Test-PwGlob $Path @($Packet.Touchpoints | ForEach-Object { $_.Path })
}

# ---------------------------------------------------------------------------------------------------
# Packet files. One Markdown file per packet or human task, in <plans>/<phase>/packets/<ID>.md:
#   # <ID> · <title>
#   - **Packet:** <ID> · **Priority:** P0 · **Size:** M · **Wave:** W1 · **Workstream:** … · **Target:** 2026-11-02
#   - **Depends on:** <ID>, <ID>       (or none)
#   - **Review lenses:** correctness, tests
#   - **Locks:** none
#   ## Goal / ## Spec / ## In scope / ## Out of scope / ## Owns / ## Shared touchpoints / ## Consumes /
#   ## Provides / ## Acceptance criteria / ## Tests to run / ## Decision record / ## Dispatcher notes
# A human task uses **Human task:** <ID> in place of **Packet:**, and may name **Parent:** <packet ID>: its
# board item then sits under that packet's item (on Azure Boards, a Task under its User Story).

function ConvertFrom-PwList {
    param([string]$Value)
    if (-not $Value) { return @() }
    $v = $Value.Trim()
    if ($v -match '^(none|n/a|-|–|—)$') { return @() }
    @($v -split '\s*,\s*' | ForEach-Object { $_.Trim().Trim('`') } | Where-Object { $_ })
}

function Read-PwPacketText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Path = '', [string]$Phase = '')
    $p = [ordered]@{
        Id = $null; Title = $null; Kind = 'packet'; Path = $Path; Phase = $Phase
        Priority = $null; Size = $null; Wave = $null; Workstream = $null; Target = $null
        DependsOn = @(); Parent = $null; Lenses = @(); Locks = @(); InitialStatus = 'Ready'; ReviewTier = $null
        Owns = @(); Excludes = @(); Touchpoints = @(); Acceptance = @(); Tests = @()
        Meta = [ordered]@{}; Sections = [ordered]@{}; HeadingId = $null; Body = ''
    }
    $section = $null
    $bodyLines = [System.Collections.Generic.List[string]]::new()
    $seenTitle = $false
    foreach ($line in ($Text -split '\r?\n')) {
        if (-not $seenTitle -and $line -match "^#\s+(?<id>$script:IdPattern)\s*[·:–—-]\s*(?<title>.+?)\s*$") {
            $p.HeadingId = $Matches.id; $p.Title = $Matches.title; $seenTitle = $true; continue
        }
        if ($seenTitle) { $bodyLines.Add($line) }
        if ($line -match '^##\s+(?<name>.+?)\s*$') {
            $section = $Matches.name.Trim()
            $p.Sections[$section] = [System.Collections.Generic.List[string]]::new()
            continue
        }
        if ($null -eq $section) {
            if ($line -match '^\s*[-*]\s+\*\*') {
                foreach ($m in [regex]::Matches($line, '\*\*(?<k>[^*:]+):\*\*\s*(?<v>[^·]*)')) {
                    $p.Meta[$m.Groups['k'].Value.Trim()] = $m.Groups['v'].Value.Trim()
                }
            }
            continue
        }
        $p.Sections[$section].Add($line)
    }
    $p.Body = ($bodyLines -join "`n").Trim()

    $meta = $p.Meta
    if ($meta.Contains('Human task')) { $p.Kind = 'human'; $p.Id = ($meta['Human task'] -split '\s')[0] }
    elseif ($meta.Contains('Packet')) { $p.Id = ($meta['Packet'] -split '\s')[0] }
    if (-not $p.Id) { $p.Id = $p.HeadingId }
    foreach ($pair in @(@('Priority', 'Priority'), @('Size', 'Size'), @('Wave', 'Wave'), @('Workstream', 'Workstream'), @('Target', 'Target'), @('Review tier', 'ReviewTier'))) {
        if ($meta.Contains($pair[0]) -and $meta[$pair[0]]) { $p[$pair[1]] = $meta[$pair[0]] }
    }
    if ($meta.Contains('Initial status') -and $meta['Initial status']) { $p.InitialStatus = $meta['Initial status'] }
    if ($meta.Contains('Phase') -and $meta['Phase'] -and -not $p.Phase) { $p.Phase = $meta['Phase'] }
    if ($meta.Contains('Depends on')) { $p.DependsOn = @([regex]::Matches($meta['Depends on'], '[A-Za-z][A-Za-z0-9]*-\d+') | ForEach-Object { $_.Value.ToUpperInvariant() } | Select-Object -Unique) }
    if ($meta.Contains('Parent')) { $p.Parent = [regex]::Matches($meta['Parent'], '[A-Za-z][A-Za-z0-9]*-\d+') | Select-Object -First 1 | ForEach-Object { $_.Value.ToUpperInvariant() } }
    if ($meta.Contains('Review lenses')) { $p.Lenses = @(ConvertFrom-PwList $meta['Review lenses'] | ForEach-Object { $_.ToLowerInvariant() }) }
    if ($meta.Contains('Locks')) { $p.Locks = @(ConvertFrom-PwList $meta['Locks']) }

    $owns = [System.Collections.Generic.List[string]]::new()
    $excludes = [System.Collections.Generic.List[string]]::new()
    if ($p.Sections.Contains('Owns')) {
        foreach ($line in $p.Sections['Owns']) {
            if ($line -match '^\s*[-*]\s+`(?<g>[^`]+)`') {
                $g = $Matches.g.Trim()
                if ($g.StartsWith('!')) { $excludes.Add($g.Substring(1)) } else { $owns.Add($g) }
            }
        }
    }
    $p.Owns = @($owns); $p.Excludes = @($excludes)
    if ($p.Sections.Contains('Shared touchpoints')) {
        $p.Touchpoints = @(foreach ($line in $p.Sections['Shared touchpoints']) {
                if ($line -match '^\s*[-*]\s+`(?<g>[^`]+)`\s*[:–—-]?\s*(?<rule>.*)$') {
                    [pscustomobject]@{ Path = $Matches.g.Trim(); Rule = $Matches.rule.Trim() }
                }
            })
    }
    if ($p.Sections.Contains('Acceptance criteria')) {
        $p.Acceptance = @(foreach ($line in $p.Sections['Acceptance criteria']) {
                if ($line -match '^\s*[-*]\s+\[(?<x>[ xX])\]\s+(?<t>.+?)\s*$') {
                    [pscustomobject]@{ Done = ($Matches.x -ne ' '); Text = $Matches.t }
                }
            })
    }
    if ($p.Sections.Contains('Tests to run')) {
        $p.Tests = @(foreach ($line in $p.Sections['Tests to run']) {
                foreach ($m in [regex]::Matches($line, '`(?<c>[^`]+)`')) { $m.Groups['c'].Value.Trim() }
            })
    }
    [pscustomobject]$p
}

function Get-PwPackets {
    <# Every packet and human task under <plans>/<phase>/packets/. -Phase limits it to one phase
       directory; the phase of a packet is the name of the directory above packets/. -Ref reads the
       files from a commit (such as origin/main) instead of the working tree. #>
    param([Parameter(Mandatory)]$Config, [string]$Phase, [string]$Ref)
    $plans = $Config.paths.plans.Trim('/').Replace('\', '/')
    if ($Ref) {
        $names = @(Invoke-PwGit ls-tree -r --name-only $Ref $plans | Where-Object { $_ })
        $files = @($names | Where-Object {
                $parts = $_ -split '/'
                $_ -like '*.md' -and $parts.Count -ge 3 -and $parts[-2] -eq 'packets' -and (-not $Phase -or $parts[-3] -eq $Phase)
            } | Sort-Object)
        return @(foreach ($rel in $files) {
                $parts = $rel -split '/'
                $text = (Invoke-PwGit show "${Ref}:$rel") -join "`n"
                Read-PwPacketText -Text $text -Path $rel -Phase $parts[-3]
            })
    }
    $dir = Join-Path $Config.repoRoot $plans
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $found = Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.md' |
        Where-Object { $_.Directory.Name -eq 'packets' -and (-not $Phase -or $_.Directory.Parent.Name -eq $Phase) } |
        Sort-Object FullName
    @(foreach ($f in $found) {
            $rel = [System.IO.Path]::GetRelativePath($Config.repoRoot, $f.FullName).Replace('\', '/')
            Read-PwPacketText -Text (Get-Content -Raw -LiteralPath $f.FullName) -Path $rel -Phase $f.Directory.Parent.Name
        })
}

function Get-PwPhaseInfo {
    <# Title and root item of a phase, from the first heading of <plans>/<phase>/plan.md and its root line:
       **Epic:**, **Feature:** or **User Story:** (or **Story:**), each naming an existing item (#<n> or
       AB#<n>). Root is that item as { Level = epic|feature|story; Ref }, or $null without exactly one such
       line; Roots lists every root line found, so a check can refuse two. Epic is the **Epic:** line's ref. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Phase, [string]$Ref)
    $rel = "$($Config.paths.plans.Trim('/'))/$Phase/plan.md"
    $text = $null
    if ($Ref) { try { $text = (Invoke-PwGit show "${Ref}:$rel") -join "`n" } catch { $text = $null } }
    else {
        $full = Join-Path $Config.repoRoot $rel
        if (Test-Path -LiteralPath $full) { $text = Get-Content -Raw -LiteralPath $full }
    }
    $title = $Phase; $epic = $null
    $roots = [System.Collections.Generic.List[object]]::new()
    if ($text) {
        # The phase's name is the heading, without a ": plan" suffix (the template's old heading).
        if ($text -match '(?m)^#\s+(?<t>.+?)\s*$') {
            $t = $Matches.t -creplace '(?:\s*:|\s+[·—–-])\s*[Pp]lan$', ''
            if ($t) { $title = $t }
        }
        # Only a real item number: the template's placeholder (#0) or a missing number means no root.
        foreach ($m in [regex]::Matches($text, '\*\*(?<k>Epic|Feature|User Story|Story):\*\*\s*(?<e>(?:AB)?#0*[1-9]\d*)\b', 'IgnoreCase')) {
            $level = switch ($m.Groups['k'].Value) { 'Epic' { 'epic' } 'Feature' { 'feature' } default { 'story' } }
            $roots.Add([pscustomobject]@{ Level = $level; Ref = $m.Groups['e'].Value; Line = $m.Groups['k'].Value })
            if ($level -eq 'epic' -and -not $epic) { $epic = $m.Groups['e'].Value }
        }
    }
    $root = if ($roots.Count -eq 1) { $roots[0] } else { $null }
    [pscustomobject]@{ Slug = $Phase; Title = $title; Epic = $epic; Root = $root; Roots = @($roots); Path = $rel; Exists = [bool]$text }
}

function Test-PwPacket {
    <# The problems in one packet file, each a string; empty when it is well formed. #>
    param([Parameter(Mandatory)]$Packet, [Parameter(Mandatory)]$Config)
    $problems = [System.Collections.Generic.List[string]]::new()
    $p = $Packet
    if (-not $p.Id) { $problems.Add('no ID: the first line must be "# <ID> · <title>" and the metadata must say **Packet:** or **Human task:**'); return , $problems }
    if ($p.HeadingId -and $p.HeadingId -ne $p.Id) { $problems.Add("heading says $($p.HeadingId) but the metadata says $($p.Id)") }
    $expectedPrefix = if ($p.Kind -eq 'human') { $Config.humanPrefix } else { $Config.packetPrefix }
    if ($p.Id -notmatch "^$expectedPrefix-\d+$") { $problems.Add("ID $($p.Id) should look like $expectedPrefix-<number>") }
    if ($p.Path) {
        $fileId = [System.IO.Path]::GetFileNameWithoutExtension($p.Path)
        if ($fileId -ne $p.Id) { $problems.Add("file name $fileId.md doesn't match the ID $($p.Id)") }
    }
    if (-not $p.Title) { $problems.Add('no title') }
    if ($p.Priority -notmatch '^P[0-3]$') { $problems.Add("Priority must be P0-P3 (got '$($p.Priority)')") }
    if ($p.Target -and $p.Target -notmatch '^\d{4}-\d{2}-\d{2}$') { $problems.Add("Target must be a date as yyyy-MM-dd (got '$($p.Target)')") }
    if ($p.InitialStatus -notin @('Backlog', 'Ready')) { $problems.Add("Initial status must be Backlog or Ready (got '$($p.InitialStatus)')") }
    # 4 is from before tiers 3 and 4 merged: still well formed (validate-packets warns; review-scope reads it as 3).
    if ($p.ReviewTier -and $p.ReviewTier -notmatch '^[1-4]$') { $problems.Add("Review tier must be 1-3, 3 being the top tier (got '$($p.ReviewTier)')") }
    if ($p.DependsOn -contains $p.Id) { $problems.Add('depends on itself') }
    if ($p.Meta.Contains('Depends on') -and $p.DependsOn.Count -eq 0 -and $p.Meta['Depends on'] -notmatch '^\s*(none|n/a|-|–|—)?\s*$') {
        $problems.Add("Depends on names no packet ID ('$($p.Meta['Depends on'])'); write IDs such as $($Config.packetPrefix)-1, or none")
    }
    if ($p.Meta.Contains('Parent') -and $p.Meta['Parent'] -notmatch '^\s*(none|n/a|-|–|—)?\s*$') {
        $parents = @([regex]::Matches($p.Meta['Parent'], '[A-Za-z][A-Za-z0-9]*-\d+') | ForEach-Object { $_.Value.ToUpperInvariant() } | Select-Object -Unique)
        if ($p.Kind -ne 'human') { $problems.Add("only a human task names a Parent: a packet's place on the board comes from the plan's root item") }
        elseif ($parents.Count -ne 1) { $problems.Add("Parent must name one packet ID, such as $($Config.packetPrefix)-1 (got '$($p.Meta['Parent'])')") }
        elseif ($p.Parent -notmatch "^$($Config.packetPrefix)-\d+$") { $problems.Add("Parent must be a packet of this repository, such as $($Config.packetPrefix)-1 (got $($p.Parent))") }
    }
    if ($p.Kind -eq 'human') {
        if ($p.Owns.Count -gt 0) { $problems.Add('a human task owns no paths') }
        return , $problems
    }
    if (-not $Config.sizes.Contains([string]$p.Size)) {
        $problems.Add("Size must be one of $(@($Config.sizes.Keys) -join ', ') (got '$($p.Size)'); a bigger packet should be split")
    }
    foreach ($s in 'Goal', 'In scope', 'Out of scope', 'Owns', 'Provides', 'Acceptance criteria', 'Tests to run') {
        if (-not $p.Sections.Contains($s) -or -not (($p.Sections[$s] -join '').Trim())) { $problems.Add("missing or empty section: $s") }
    }
    if ($p.Owns.Count -eq 0) { $problems.Add('Owns lists no paths (each entry is a backticked glob on its own bullet)') }
    if ($p.Acceptance.Count -eq 0) { $problems.Add('Acceptance criteria has no "- [ ] …" items') }
    if ($p.Tests.Count -eq 0) { $problems.Add('Tests to run has no backticked command') }
    if ($p.Lenses.Count -eq 0) { $problems.Add('Review lenses is empty (at least correctness)') }
    foreach ($lock in $p.Locks) {
        if (-not (@($Config.locks) | Where-Object { $_.name -eq $lock })) { $problems.Add("lock '$lock' isn't defined in the config's locks") }
    }
    , $problems
}

# ---------------------------------------------------------------------------------------------------
# Dependency graph.

function Get-PwAncestors {
    <# id -> HashSet of every packet it depends on, directly or not. Cycles are cut, not followed. #>
    param([Parameter(Mandatory)]$Packets)
    $byId = @{}; foreach ($p in $Packets) { $byId[$p.Id] = $p }
    $memo = @{}
    $visit = $null
    $visit = {
        param($id, $stack)
        if ($memo.ContainsKey($id)) { return $memo[$id] }
        $set = [System.Collections.Generic.HashSet[string]]::new()
        if ($byId.ContainsKey($id)) {
            foreach ($d in $byId[$id].DependsOn) {
                if ($stack.Contains($d)) { continue }
                [void]$set.Add($d)
                [void]$stack.Add($d)
                foreach ($a in (& $visit $d $stack)) { [void]$set.Add($a) }
                [void]$stack.Remove($d)
            }
        }
        $memo[$id] = $set
        , $set
    }
    foreach ($p in $Packets) {
        $stack = [System.Collections.Generic.HashSet[string]]::new(); [void]$stack.Add($p.Id)
        [void](& $visit $p.Id $stack)
    }
    $memo
}

function Get-PwCycles {
    param([Parameter(Mandatory)]$Packets)
    $byId = @{}; foreach ($p in $Packets) { $byId[$p.Id] = $p }
    $color = @{}; $cycles = [System.Collections.Generic.List[string]]::new()
    $path = [System.Collections.Generic.List[string]]::new()
    $dfs = $null
    $dfs = {
        param($id)
        $color[$id] = 1; $path.Add($id)
        if ($byId.ContainsKey($id)) {
            foreach ($d in $byId[$id].DependsOn) {
                if (-not $byId.ContainsKey($d)) { continue }
                if (-not $color.ContainsKey($d)) { & $dfs $d }
                elseif ($color[$d] -eq 1) {
                    $start = $path.IndexOf($d)
                    $cycles.Add((@($path.GetRange($start, $path.Count - $start)) + $d) -join ' -> ')
                }
            }
        }
        $color[$id] = 2; $path.RemoveAt($path.Count - 1)
    }
    foreach ($p in $Packets) { if (-not $color.ContainsKey($p.Id)) { & $dfs $p.Id } }
    , @($cycles)
}

function Get-PwCriticalPath {
    <# The heaviest dependency chain among the packets -Include keeps (default: all), weighted by size
       (config sizes; a human task weighs 1). Returns @{ Weight; Path = ids from first to last }.
       Pass -Include as a closure ({ … }.GetNewClosure()): a plain script block resolves its variables
       here, at call time, where this function's own names would shadow the caller's. #>
    param([Parameter(Mandatory)]$Packets, [Parameter(Mandatory)]$Config, [scriptblock]$Include = { $true })
    $cpKept = @{}; foreach ($cpPacket in $Packets) { if (& $Include $cpPacket) { $cpKept[$cpPacket.Id] = $cpPacket } }
    $cpMemo = @{}
    $cpBest = $null
    $cpBest = {
        param($cpId, $cpDepth)
        if ($cpMemo.ContainsKey($cpId)) { return $cpMemo[$cpId] }
        if ($cpDepth -gt 200) { return @{ Weight = 0; Path = @() } }
        $cpP = $cpKept[$cpId]
        $cpW = if ($cpP.Kind -eq 'human') { 1 } elseif ($Config.sizes.Contains([string]$cpP.Size)) { [int]$Config.sizes[[string]$cpP.Size] } else { 2 }
        $cpTop = @{ Weight = 0; Path = @() }
        foreach ($cpDep in $cpP.DependsOn) {
            if (-not $cpKept.ContainsKey($cpDep)) { continue }
            $cpR = & $cpBest $cpDep ($cpDepth + 1)
            if ($cpR.Weight -gt $cpTop.Weight) { $cpTop = $cpR }
        }
        $cpRes = @{ Weight = $cpTop.Weight + $cpW; Path = @($cpTop.Path) + $cpId }
        $cpMemo[$cpId] = $cpRes
        $cpRes
    }
    $cpAnswer = @{ Weight = 0; Path = @() }
    foreach ($cpId in ($cpKept.Keys | Sort-Object)) {
        $cpR = & $cpBest $cpId 0
        if ($cpR.Weight -gt $cpAnswer.Weight) { $cpAnswer = $cpR }
    }
    $cpAnswer
}

# ---------------------------------------------------------------------------------------------------
# Verdicts. An item is the board's view of a packet: Id, Ref, Status, Closed, ClosedReason, Kind.
#   START    every dependency is Done: branch from the default branch.
#   STACK    (only with "stacking": true) exactly one dependency is Ready to merge with an open PR
#            against the default branch, and the rest are Done: branch from that PR's head.
#   BLOCKED  anything else; Reasons says which dependency and why.
# A dependency in another repository (remotes) is an item from Get-PwRemoteItems: Done only when its issue
# there was closed as completed, and never a STACK base.

function Get-PwRemoteRepo {
    <# The repository (owner/name) the config's remotes give a packet ID's prefix; $null for this repository's IDs. #>
    param([Parameter(Mandatory)]$Config, [string]$Id)
    $prefix = ($Id -split '-')[0]
    if ($Config.remotes -and $Config.remotes.Contains($prefix)) { [string]$Config.remotes[$prefix].repo } else { $null }
}

function Test-PwRemoteItem {
    param($Item)
    [bool]($Item -and $Item.PSObject.Properties['Remote'] -and $Item.Remote)
}

function Test-PwItemDone {
    param($Item)
    if (-not $Item) { return $false }
    if (Test-PwRemoteItem $Item) { return [bool]$Item.Done }
    if ($Item.Closed -and $Item.ClosedReason -ne 'not_planned') { return $true }
    $Item.Status -eq 'Done'
}

function Get-PwVerdict {
    param(
        [Parameter(Mandatory)]$Packet,
        [Parameter(Mandatory)][hashtable]$ItemsById,
        [Parameter(Mandatory)]$Config,
        [scriptblock]$FindOpenPr
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    $stackCandidates = [System.Collections.Generic.List[string]]::new()
    foreach ($d in $Packet.DependsOn) {
        $item = $ItemsById[$d]
        if (-not $item) { $reasons.Add("$d is not on the board"); continue }
        if (Test-PwItemDone $item) { continue }
        if (Test-PwRemoteItem $item) { $reasons.Add($item.Reason); continue }
        if ($item.Closed -and $item.ClosedReason -eq 'not_planned') { $reasons.Add("$d was closed as not planned"); continue }
        if ($item.Status -eq 'Ready to merge' -and $item.Kind -ne 'human') { $stackCandidates.Add($d); continue }
        $reasons.Add("$d is $($item.Status)")
    }
    $verdict = 'START'; $stackOn = $null; $stackPr = $null
    if ($reasons.Count -gt 0) { $verdict = 'BLOCKED' }
    if ($stackCandidates.Count -gt 0) {
        if (-not $Config.stacking) {
            $verdict = 'BLOCKED'
            foreach ($d in $stackCandidates) { $reasons.Add("$d is Ready to merge (stacking is off: wait for the merge)") }
        }
        elseif ($stackCandidates.Count -gt 1) {
            $verdict = 'BLOCKED'
            $reasons.Add("$($stackCandidates -join ', ') are all Ready to merge; a packet stacks on one dependency at most")
        }
        elseif ($verdict -eq 'START') {
            $d = $stackCandidates[0]
            $pr = if ($FindOpenPr) { & $FindOpenPr $d } else { $null }
            if (-not $pr) { $verdict = 'BLOCKED'; $reasons.Add("$d is Ready to merge but has no open PR") }
            elseif ($pr.baseRefName -ne $Config.defaultBranch) { $verdict = 'BLOCKED'; $reasons.Add("$d is itself stacked (PR #$($pr.number) targets $($pr.baseRefName)); stacks are one deep") }
            else { $verdict = 'STACK'; $stackOn = $d; $stackPr = $pr }
        }
        else {
            foreach ($d in $stackCandidates) { $reasons.Add("$d is Ready to merge") }
        }
    }
    [pscustomobject]@{ Id = $Packet.Id; Verdict = $verdict; Reasons = @($reasons); StackOn = $stackOn; StackPr = $stackPr }
}

# ---------------------------------------------------------------------------------------------------
# Markers. Comments the workflow writes start with a code span: `packet:<kind> key=value …`. They are
# visible text on purpose, so they survive every board's comment renderer.

function Get-PwMarker {
    param([string]$Body)
    if (-not $Body) { return $null }
    # A board that hands comments back as HTML turns the code span into <code>…</code>.
    $m = [regex]::Match($Body, '(?:`|<code>)packet:(?<kind>[a-z-]+)(?<rest>[^`<\r\n]*)(?:`|</code>)')
    if (-not $m.Success) { return $null }
    $rest = $m.Groups['rest'].Value.Trim()
    $pairs = @{}
    $words = [System.Collections.Generic.List[string]]::new()
    foreach ($tok in ($rest -split '\s+' | Where-Object { $_ })) {
        if ($tok -match '^(?<k>[A-Za-z][\w-]*)=(?<v>.*)$') { $pairs[$Matches.k] = $Matches.v } else { $words.Add($tok) }
    }
    [pscustomobject]@{ Kind = $m.Groups['kind'].Value; Words = @($words); Pairs = $pairs }
}

# ---------------------------------------------------------------------------------------------------
# Credit estimates (docs/cost.md). Counts come from a PR's trusted round markers; credits per run from
# budget.creditsPerRun. Estimates only: Copilot reports no tokens to the agents, so calibrate the table
# against the AI usage report. Resume sessions and CI-fix runs leave no marker and aren't counted.

function Get-PwField {
    <# A field of a row that may be a hashtable or an object, or $null when it has none (strict mode). #>
    param($Row, [string]$Name)
    if ($null -eq $Row) { return $null }
    if ($Row -is [System.Collections.IDictionary]) { return $Row[$Name] }
    $p = $Row.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

function Get-PwRoundRows {
    <# The round reports among a PR's marker rows (settle requests and checks left out). #>
    param([object[]]$Rows = @())
    , @($Rows | Where-Object { $null -ne $_ -and (($k = Get-PwField $_ 'Kind') -eq 'round' -or -not $k) })
}

function Get-PwSum {
    <# The sum of one numeric field over rows; 0 for none (Measure-Object prints nothing then). #>
    param([object[]]$Rows = @(), [Parameter(Mandatory)][string]$Name)
    $sum = 0.0
    foreach ($r in $Rows) { if ($null -ne $r) { $v = Get-PwField $r $Name; if ($null -ne $v) { $sum += [double]$v } } }
    $sum
}

function Get-PwCreditRate {
    <# A creditsPerRun entry for a size: a number, or a table by S/M/L. Stops on anything else, so a
       typo in the budget stops the estimate (never the board, which doesn't read it). #>
    param($Table, [string]$Name, [string]$Size, $Default)
    $v = $Table[$Name]
    if ($null -eq $v -and $null -ne $Default) { return [double]$Default }
    if ($v -is [System.Collections.IDictionary]) { $v = $v[$Size] }
    if ($v -isnot [ValueType] -or $v -is [bool]) { Stop-Pw "config: budget.creditsPerRun.$Name must be a number, or a number per size (S, M, L); its $Size value is missing or not a number" }
    [double]$v
}

function Get-PwCreditEstimate {
    <# One packet's credits from its round markers (rows with Round, Tier, Lenses, Runs, Outcome,
       CreatedAt, as board.ps1 rounds returns them), priced with budget.creditsPerRun:
         base   dispatcher + implementer (preflight, brief, PR, hand-off; the first implementer run)
         round  dispatcherPerRound + dispatcherPerReviewerRun × runs + reviewers + implementerFix if it was a fix
       Reviewers: reviewerByTier[size][tier] for each run, a run of n lenses counting 1 + 0.4 (n - 1),
       times laterRoundFactor from round 2 on. A round without runs= ran one reviewer per lens; a round
       without a tier, or with tier=4 (written before tiers 3 and 4 merged), is priced at tier 3. A
       four-number reviewerByTier (an install from before the merge) drops its third: tier 3 now does
       what its tier 4 did. #>
    param([Parameter(Mandatory)]$Config, [string]$Size, [object[]]$Rounds = @())
    $t = $Config.budget.creditsPerRun
    $sz = if ($Size -in 'S', 'M', 'L') { $Size } else { 'M' }
    $dispatcher = Get-PwCreditRate $t 'dispatcher' $sz
    $perRound = Get-PwCreditRate $t 'dispatcherPerRound' $sz
    $perRun = Get-PwCreditRate $t 'dispatcherPerReviewerRun' $sz 0
    $later = Get-PwCreditRate $t 'laterRoundFactor' $sz 1
    $implementer = Get-PwCreditRate $t 'implementer' $sz
    $implementerFix = Get-PwCreditRate $t 'implementerFix' $sz
    $listed = @($t.reviewerByTier[$sz])
    $byTier = @($listed | Where-Object { $_ -is [ValueType] -and $_ -isnot [bool] })
    if ($listed.Count -eq 4 -and $byTier.Count -eq 4) { $byTier = @($byTier[0], $byTier[1], $byTier[3]) }
    elseif ($listed.Count -ne 3 -or $byTier.Count -ne 3) { Stop-Pw "config: budget.creditsPerRun.reviewerByTier.$sz must list three numbers, tiers 1 to 3" }
    $rows = @(foreach ($r in (Get-PwRoundRows $Rounds)) {
            $tier = 3
            if ("$(Get-PwField $r 'Tier')" -match '^[1-4]$') { $tier = [Math]::Min(3, [int](Get-PwField $r 'Tier')) }
            $lenses = @("$(Get-PwField $r 'Lenses')" -split '[,\s]+' | Where-Object { $_ -and $_ -ne '-' })
            $n = [Math]::Max(1, $lenses.Count)
            $given = "$(Get-PwField $r 'Runs')"
            $runs = if ($given -match '^\d+$' -and [int]$given -ge 1) { [Math]::Min([int]$given, $n) } else { $n }
            $round = [int](Get-PwField $r 'Round')
            $reviewers = [double]$byTier[$tier - 1] * ($runs + 0.4 * ($n - $runs)) * $(if ($round -ge 2) { $later } else { 1 })
            $fix = "$(Get-PwField $r 'Outcome')" -eq 'fix'
            $credits = $perRound + $perRun * $runs + $reviewers + $(if ($fix) { $implementerFix } else { 0 })
            [pscustomobject]@{ Round = $round; Tier = $tier; Lenses = $n; ReviewerRuns = $runs; Fix = $fix; Credits = [Math]::Round($credits); CreatedAt = (Get-PwField $r 'CreatedAt') }
        })
    $base = $dispatcher + $implementer
    [pscustomobject]@{
        Size = $sz; Base = [Math]::Round($base); Rounds = $rows
        ReviewerRuns = [int](Get-PwSum $rows 'ReviewerRuns')
        ImplementerRuns = 1 + @($rows | Where-Object Fix).Count
        Credits = [Math]::Round($base + (Get-PwSum $rows 'Credits'))
    }
}

function Get-PwCreditSummary {
    <# A phase's estimated credits. -Packets: objects with Id, Size, Pr and Rounds (round marker rows).
       -Today is a UTC date: the AI-credit pool resets on the 1st, UTC. This month counts each round in
       the UTC month of its report, and a packet's base (preflight, brief, first implementer run) in the
       month of its round 1. A packet is finished once its last round passed or went to the owner. #>
    param([Parameter(Mandatory)]$Config, [object[]]$Packets = @(), [DateTime]$Today = [DateTime]::UtcNow)
    $month = [DateTime]::new($Today.Year, $Today.Month, 1)
    $inMonth = { param($at) if (-not $at) { return $false }; $d = ([DateTimeOffset]$at).UtcDateTime; $d.Year -eq $month.Year -and $d.Month -eq $month.Month }
    $rows = @(foreach ($p in $Packets) {
            $rounds = Get-PwRoundRows @(Get-PwField $p 'Rounds')
            if (-not $rounds.Count) { continue }
            $e = Get-PwCreditEstimate -Config $Config -Size (Get-PwField $p 'Size') -Rounds $rounds
            $mtd = Get-PwSum @($e.Rounds | Where-Object { & $inMonth $_.CreatedAt }) 'Credits'
            if (& $inMonth ($e.Rounds | Select-Object -First 1).CreatedAt) { $mtd += $e.Base }
            $lastOutcome = "$(Get-PwField ($rounds | Select-Object -Last 1) 'Outcome')"
            [pscustomobject]@{
                Id = (Get-PwField $p 'Id'); Size = $e.Size; Pr = (Get-PwField $p 'Pr'); Rounds = $e.Rounds.Count; ReviewerRuns = $e.ReviewerRuns; ImplementerRuns = $e.ImplementerRuns
                Credits = $e.Credits; ThisMonth = [Math]::Round($mtd); Finished = $lastOutcome -in 'pass', 'needs-human'
            }
        })
    $finished = @($rows | Where-Object Finished)
    $avgOf = @(if ($finished.Count) { $finished } else { $rows })
    $avg = if ($avgOf.Count) { [Math]::Round((Get-PwSum $avgOf 'Credits') / $avgOf.Count) } else { 0 }
    $total = Get-PwSum $rows 'Credits'
    $mtdAll = Get-PwSum $rows 'ThisMonth'
    $monthly = [int]$Config.budget.monthlyCredits
    [pscustomobject]@{
        Estimate = $true; Packets = $rows; Total = [Math]::Round($total); PerFinishedPacket = $avg
        Month = $month.ToString('yyyy-MM'); ThisMonth = [Math]::Round($mtdAll); MonthlyCredits = $monthly
        Left = $(if ($monthly) { [Math]::Round($monthly - $mtdAll) } else { $null })
        PacketsLeft = $(if ($monthly -and $avg) { [Math]::Max(0, [Math]::Floor(($monthly - $mtdAll) / $avg)) } else { $null })
    }
}

function New-PwClaimId {
    # Claims are public comments, so the machine shows only as a short hash: sessions on one machine
    # share it, and a public repository doesn't learn the host or user name.
    $machine = (Get-PwSha256 "$([System.Net.Dns]::GetHostName())|$([Environment]::UserName)").Substring(0, 8)
    'session-{0}-{1}-{2}' -f $machine, [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'), (Get-Random -Minimum 10000 -Maximum 99999)
}

$script:PwTrusted = $null

function Test-PwTrustedAuthor {
    <# True for the signed-in user (Get-ProvCurrentUser) and anyone in the config's trustedAuthors.
       Markers (claims, briefs, rounds, settles) count only from them: anyone who can comment could
       otherwise forge a passed round or a brief. #>
    param([string]$Author)
    if (-not $Author) { return $false }
    if ($null -eq $script:PwTrusted) {
        $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $me = Get-ProvCurrentUser
        if (-not $me) { Stop-Pw 'could not tell who is signed in, so no marker can be trusted' }
        [void]$set.Add($me)
        foreach ($a in @($script:PwConfig.trustedAuthors)) { if ($a) { [void]$set.Add([string]$a) } }
        $script:PwTrusted = $set
    }
    $script:PwTrusted.Contains($Author)
}

function Get-PwTrustedComments {
    <# The item's comments by trusted authors, oldest first. #>
    param([Parameter(Mandatory)][string]$Ref)
    @(Get-ProvComments -Ref $Ref | Where-Object { Test-PwTrustedAuthor $_.Author } | Sort-Object CreatedAt, { [long]$_.Id })
}

function Get-PwClaimComments {
    <# Claim comments by trusted authors on an item, oldest first. #>
    param([Parameter(Mandatory)][string]$Ref)
    @(Get-PwTrustedComments -Ref $Ref | ForEach-Object {
            $mk = Get-PwMarker $_.Body
            if ($mk -and $mk.Kind -eq 'claim' -and $mk.Words.Count -ge 1) {
                [pscustomobject]@{ ClaimId = $mk.Words[0]; CreatedAt = [DateTimeOffset]$_.CreatedAt; CommentId = $_.Id }
            }
        } | Sort-Object CreatedAt, { [long]$_.CommentId })
}

function Get-PwBoardNow {
    <# The latest the board's clock can read now, from a response's Date header (whole seconds) and the
       local time the request went out: the server stamped Date between then and the response, so its
       clock is at most Date + 1s + the local time since. Claims are judged by the board's clock, never
       the local one: two machines' clocks can be minutes apart. #>
    param([Parameter(Mandatory)][DateTimeOffset]$Date, [Parameter(Mandatory)][DateTimeOffset]$SentAt)
    $Date.AddSeconds(1) + ([DateTimeOffset]::UtcNow - $SentAt)
}

function ConvertFrom-PwHttpDate {
    param([string]$Text)
    $d = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { Stop-Pw "the board sent a Date header that isn't a date ('$Text'), so its clock is unknown" }
    $d.ToUniversalTime()
}

function Select-PwClaimHolder {
    <# The holder as of board time -At: the oldest claim in the lease window ending there (ties: the lower
       comment id). The claim check and the read-only check both decide with this. #>
    param([object[]]$Claims, [Parameter(Mandatory)][DateTimeOffset]$At, [Parameter(Mandatory)][int]$LeaseMinutes)
    $from = $At.AddMinutes(-$LeaseMinutes)
    @($Claims | Where-Object { $_.CreatedAt -ge $from -and $_.CreatedAt -le $At } | Sort-Object CreatedAt, { [long]$_.CommentId }) | Select-Object -First 1
}

function Invoke-PwClaim {
    <# The claim check. A claim lasts LeaseMinutes after its newest comment, by the board's clock; it is
       renewed once a third of that has passed.

       Read-only first: if this claim id already has a comment and another claim holds the window that
       ends at its newest comment (Select-PwClaimHolder), it is LOST, with nothing written, -Force or not.
       If that window is ours and more than two thirds of the lease is left by the latest
       the board's clock can read (Get-ProvBoardNow), the claim still holds and nothing is written. That
       comment won its own window, so any claim posted after it within the lease saw it and lost; no one
       else can hold until it lapses.

       Otherwise (a first claim, one that is due, a lapsed one, or -Force) it posts a claim comment, then
       reads the claims in the lease window before it, by the board's clock. The oldest claim in that window
       holds the packet. On LOST the comment it posted is deleted again. On HOLD nothing else is deleted:
       a holder's older claim must stay visible until release, or a session that posted just before this
       renewal could read a window without it and hold too. A failed call throws: a failed check is never
       a win. One exception: a due renewal that loses to a claim comment left behind (one that lost its
       own check) deletes its comment and still holds on the newest earlier one, if that hasn't lapsed and
       more than a minute of it is left; Deferred names the left-behind claim.

       Returns @{ Result = 'HOLD'|'LOST'; ClaimId; CreatedAt; CommentId } for the holder, plus Renewed (a
       comment was posted), Lapsed (this claim had lapsed before it renewed: someone may have held and
       released it meanwhile) and Left (the lease left, for HOLD). #>
    param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)][string]$ClaimId, [Parameter(Mandatory)][int]$LeaseMinutes, [switch]$Force)
    if ($ClaimId -notmatch '^[A-Za-z0-9._-]+$') { Stop-Pw "claim id '$ClaimId' may only use letters, digits, '.', '_' and '-'" }
    $lease = [TimeSpan]::FromMinutes($LeaseMinutes)
    $renewBelow = [TimeSpan]::FromMinutes($LeaseMinutes * 2 / 3)
    $lapsed = $false
    $claims = @(Get-PwClaimComments -Ref $Ref)
    $newest = @($claims | Where-Object { $_.ClaimId -eq $ClaimId }) | Select-Object -Last 1
    if ($newest) {
        # Even with -Force: a comment of ours that lost its own window (one left behind by a failed delete
        # or a crash) must not turn into a hold once the claim that beat it ages out of a newer window.
        $holder = Select-PwClaimHolder -Claims $claims -At $newest.CreatedAt -LeaseMinutes $LeaseMinutes
        if ($holder.ClaimId -ne $ClaimId) {
            return [pscustomobject]@{ Result = 'LOST'; ClaimId = $holder.ClaimId; CreatedAt = $holder.CreatedAt; CommentId = $holder.CommentId; Renewed = $false; Lapsed = $false; Left = $null }
        }
        $left = $newest.CreatedAt + $lease - (Get-ProvBoardNow)
        if (-not $Force -and $left -gt $renewBelow) {
            return [pscustomobject]@{ Result = 'HOLD'; ClaimId = $ClaimId; CreatedAt = $newest.CreatedAt; CommentId = $newest.CommentId; Renewed = $false; Lapsed = $false; Left = $left }
        }
        $lapsed = $left -le [TimeSpan]::Zero
    }
    $body = "``packet:claim $ClaimId`` A dispatcher session is working on this packet. The claim lapses $LeaseMinutes minutes after its newest refresh."
    $posted = Add-ProvComment -Ref $Ref -Body $body
    try {
        $mine = [DateTimeOffset]$posted.CreatedAt
        $window = @(Get-PwClaimComments -Ref $Ref)
        if (-not ($window | Where-Object { [string]$_.CommentId -eq [string]$posted.Id })) {
            # Our own comment isn't visible yet: treat it as the newest in the window.
            $window += [pscustomobject]@{ ClaimId = $ClaimId; CreatedAt = $mine; CommentId = $posted.Id }
        }
        $holder = Select-PwClaimHolder -Claims $window -At $mine -LeaseMinutes $LeaseMinutes
    }
    catch {
        try { [void](Remove-ProvComment -Ref $Ref -CommentId $posted.Id) } catch { }
        throw
    }
    if ($holder.ClaimId -eq $ClaimId) {
        return [pscustomobject]@{ Result = 'HOLD'; ClaimId = $ClaimId; CreatedAt = $mine; CommentId = $posted.Id; Renewed = $true; Lapsed = $lapsed; Left = $lease }
    }
    [void](Remove-ProvComment -Ref $Ref -CommentId $posted.Id)
    if ($newest -and -not $lapsed -and ($claims | Where-Object { [string]$_.CommentId -eq [string]$holder.CommentId })) {
        # Our newest comment held its own window and hasn't lapsed, yet an older claim, one the first read
        # saw too, fills this one. It is older than our oldest comment in the window ending at our newest,
        # so it lost its own check: a comment left behind by a failed delete or a crash. It can't hold, and
        # no claim posted after our newest comment can either, so the claim still holds until that comment
        # lapses (measured again: the post and read may have been slow). The renewal waits until the
        # left-behind comment ages out, which is before ours does. A winner the first read didn't see may
        # be a real holder whose comment showed up late: that stays LOST.
        $left = $newest.CreatedAt + $lease - (Get-ProvBoardNow)
        if ($left -gt [TimeSpan]::FromMinutes(1)) {
            return [pscustomobject]@{ Result = 'HOLD'; ClaimId = $ClaimId; CreatedAt = $newest.CreatedAt; CommentId = $newest.CommentId; Renewed = $false; Lapsed = $false; Left = $left; Deferred = $holder.ClaimId }
        }
    }
    [pscustomobject]@{ Result = 'LOST'; ClaimId = $holder.ClaimId; CreatedAt = $holder.CreatedAt; CommentId = $holder.CommentId; Renewed = $false; Lapsed = $false; Left = $null }
}

function Remove-PwClaim {
    <# Deletes every claim comment of this claim id. Returns how many it deleted. #>
    param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)][string]$ClaimId)
    $n = 0
    foreach ($c in (Get-PwClaimComments -Ref $Ref | Where-Object { $_.ClaimId -eq $ClaimId })) {
        [void](Remove-ProvComment -Ref $Ref -CommentId $c.CommentId)
        $n++
    }
    $n
}

function Get-PwLiveClaims {
    <# Claims made in the last lease window by the board's clock, and that clock's reading (Now). It only
       reports; the claim check decides. #>
    param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)][int]$LeaseMinutes)
    $claims = @(Get-PwClaimComments -Ref $Ref)
    $now = Get-ProvBoardNow
    $from = $now.AddMinutes(-$LeaseMinutes)
    [pscustomobject]@{ Now = $now; Claims = @($claims | Where-Object { $_.CreatedAt -ge $from }) }
}

# ---------------------------------------------------------------------------------------------------
# Helpers shared by the scripts.

function Get-PwSlug {
    param([string]$Text, [int]$MaxWords = 5)
    $words = @(($Text.ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim() -split '\s+' | Where-Object { $_ } | Select-Object -First $MaxWords)
    $words -join '-'
}

function Get-PwBranchName {
    param([Parameter(Mandatory)]$Packet)
    "pkt/$($Packet.Id.ToLowerInvariant())-$(Get-PwSlug $Packet.Title)"
}

function Get-PwSha256 {
    param([string]$Text)
    $norm = (($Text -replace '\r\n?', "`n") -split "`n" | ForEach-Object { $_.TrimEnd() }) -join "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($norm.Trim())
    ([System.Security.Cryptography.SHA256]::HashData($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
}

function Invoke-PwGit {
    # Runs git and returns its stdout lines; throws with stderr on failure. A simple function on purpose:
    # an advanced one would bind -C or -r as its own parameters. Don't pass a bare --; PowerShell drops it.
    $GitArgs = @('-c', 'core.quotePath=false') + @($args)
    $err = [System.IO.Path]::GetTempFileName()
    try {
        $out = & git @GitArgs 2>$err
        if ($LASTEXITCODE -ne 0) { Stop-Pw "git $($GitArgs -join ' ') failed: $((Get-Content -Raw $err).Trim())" }
        $out
    }
    finally { Remove-Item -LiteralPath $err -ErrorAction SilentlyContinue }
}

