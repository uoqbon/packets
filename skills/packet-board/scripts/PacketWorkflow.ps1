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
        azureBoards   = @{ workItemType = 'User Story'; humanWorkItemType = 'Task'; areaPath = ''; iterationPath = ''; doneStates = @('Closed', 'Removed'); priorityField = 'Microsoft.VSTS.Common.Priority'; targetDateField = ''; markdown = $true }
    }
    labels        = @{ packet = 'packet'; human = 'human-task'; needsHuman = 'needs-human'; followUp = 'follow-up' }
    commands      = @{ test = ''; ci = '' }
    guardrails    = @{ protectedBranches = @('main'); forbiddenCommands = @(); rules = @() }
    locks         = @()
    stacking      = $false
    trustedAuthors = @()
    claims        = @{ leaseMinutes = 30 }
    review        = @{
        maxRounds = 3; maxParallelLenses = 2
        agents = @{ '1' = 'packet-reviewer-light'; '2' = 'packet-reviewer-standard'; '3' = 'packet-reviewer-deep'; '4' = 'packet-reviewer-max' }
        maxPaths = ''; deepPaths = ''; lensPaths = @{}; concurrencyPattern = ''
        lensOrder = @('security', 'data', 'concurrency', 'ai', 'integration', 'ops', 'architecture', 'correctness', 'ux', 'performance', 'tests')
    }
    sizes         = @{ S = 1; M = 2; L = 3 }
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
            foreach ($s in $script:Statuses) {
                if (-not $ab.statusMap -or -not $ab.statusMap[$s] -or -not $ab.statusMap[$s].state) { Stop-Pw "config: board.azureBoards.statusMap needs a state for '$s'" }
            }
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
    if ([int]$cfg.claims.leaseMinutes -lt 5) { Stop-Pw 'config: claims.leaseMinutes must be at least 5' }
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
# A human task uses **Human task:** <ID> in place of **Packet:**.

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
        DependsOn = @(); Lenses = @(); Locks = @(); InitialStatus = 'Ready'; ReviewTier = $null
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
    <# Title and epic of a phase, from the first heading and the **Epic:** line of <plans>/<phase>/plan.md. #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Phase, [string]$Ref)
    $rel = "$($Config.paths.plans.Trim('/'))/$Phase/plan.md"
    $text = $null
    if ($Ref) { try { $text = (Invoke-PwGit show "${Ref}:$rel") -join "`n" } catch { $text = $null } }
    else {
        $full = Join-Path $Config.repoRoot $rel
        if (Test-Path -LiteralPath $full) { $text = Get-Content -Raw -LiteralPath $full }
    }
    $title = $Phase; $epic = $null
    if ($text) {
        if ($text -match '(?m)^#\s+(?<t>.+?)\s*$') { $title = $Matches.t }
        if ($text -match '\*\*Epic:\*\*\s*(?<e>(?:AB)?#\d+)') { $epic = $Matches.e }
    }
    [pscustomobject]@{ Slug = $Phase; Title = $title; Epic = $epic; Path = $rel; Exists = [bool]$text }
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
    if ($p.ReviewTier -and $p.ReviewTier -notmatch '^[1-4]$') { $problems.Add("Review tier must be 1-4 (got '$($p.ReviewTier)')") }
    if ($p.DependsOn -contains $p.Id) { $problems.Add('depends on itself') }
    if ($p.Meta.Contains('Depends on') -and $p.DependsOn.Count -eq 0 -and $p.Meta['Depends on'] -notmatch '^\s*(none|n/a|-|–|—)?\s*$') {
        $problems.Add("Depends on names no packet ID ('$($p.Meta['Depends on'])'); write IDs such as $($Config.packetPrefix)-1, or none")
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

function Test-PwItemDone {
    param($Item)
    if (-not $Item) { return $false }
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

function New-PwClaimId {
    $hostName = ([System.Net.Dns]::GetHostName() -split '\.')[0] -replace '[^A-Za-z0-9-]', ''
    if (-not $hostName) { $hostName = 'host' }
    '{0}-{1}-{2}' -f $hostName, [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'), (Get-Random -Minimum 10000 -Maximum 99999)
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

function Invoke-PwClaim {
    <# The claim check. Posts a claim comment, then reads the claims in the lease window before it, by
       the board's clock. The oldest claim in that window holds the packet (ties: the lower comment id).
       Returns @{ Result = 'HOLD'|'LOST'; ClaimId; CreatedAt; CommentId } for the holder. On LOST the
       comment it posted is deleted again. On HOLD nothing else is deleted: a holder's older claim must
       stay visible until release, or a session that posted just before this refresh could read a window
       without it and hold too. A failed call throws: a failed check is never a win. #>
    param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)][string]$ClaimId, [Parameter(Mandatory)][int]$LeaseMinutes)
    if ($ClaimId -notmatch '^[A-Za-z0-9._-]+$') { Stop-Pw "claim id '$ClaimId' may only use letters, digits, '.', '_' and '-'" }
    $body = "``packet:claim $ClaimId`` A dispatcher session is working on this packet. The claim lapses $LeaseMinutes minutes after its newest refresh."
    $posted = Add-ProvComment -Ref $Ref -Body $body
    try {
        $mine = [DateTimeOffset]$posted.CreatedAt
        $from = $mine.AddMinutes(-$LeaseMinutes)
        $window = @(Get-PwClaimComments -Ref $Ref | Where-Object { $_.CreatedAt -ge $from -and $_.CreatedAt -le $mine })
        if (-not ($window | Where-Object { [string]$_.CommentId -eq [string]$posted.Id })) {
            # Our own comment isn't visible yet: treat it as the newest in the window.
            $window += [pscustomobject]@{ ClaimId = $ClaimId; CreatedAt = $mine; CommentId = $posted.Id }
        }
        $holder = $window | Sort-Object CreatedAt, { [long]$_.CommentId } | Select-Object -First 1
    }
    catch {
        try { [void](Remove-ProvComment -Ref $Ref -CommentId $posted.Id) } catch { }
        throw
    }
    if ($holder.ClaimId -eq $ClaimId) {
        return [pscustomobject]@{ Result = 'HOLD'; ClaimId = $ClaimId; CreatedAt = $mine; CommentId = $posted.Id }
    }
    [void](Remove-ProvComment -Ref $Ref -CommentId $posted.Id)
    [pscustomobject]@{ Result = 'LOST'; ClaimId = $holder.ClaimId; CreatedAt = $holder.CreatedAt; CommentId = $holder.CommentId }
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
    <# Claims made in the last lease window by the local clock. It only reports; the claim check decides. #>
    param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)][int]$LeaseMinutes)
    $from = [DateTimeOffset]::UtcNow.AddMinutes(-$LeaseMinutes)
    @(Get-PwClaimComments -Ref $Ref | Where-Object { $_.CreatedAt -ge $from })
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

