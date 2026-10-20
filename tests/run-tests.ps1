#!/usr/bin/env pwsh
#Requires -Version 7.2
<#
.SYNOPSIS
  run-tests.ps1: offline tests for the kit's scripts.

.DESCRIPTION
  Builds a throwaway git repository with a sample phase, then runs validate-packets.ps1, board.ps1
  (with the local provider), review-scope.ps1, check-scope.ps1 and progress.ps1 against it and checks
  their output and exit codes. Needs only pwsh and git: no network, no GitHub, no Azure DevOps.

  pwsh -File tests/run-tests.ps1 [-Keep]      -Keep leaves the temp repository for inspection
#>
param([switch]$Keep)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$kit = Split-Path -Parent $PSScriptRoot
$skills = Join-Path $kit 'skills'
$board = Join-Path $skills 'packet-board/scripts/board.ps1'
$validate = Join-Path $skills 'packet-plan/scripts/validate-packets.ps1'
$reviewScope = Join-Path $skills 'packet-review/scripts/review-scope.ps1'
$checkScope = Join-Path $skills 'packet-dispatch/scripts/check-scope.ps1'
$progress = Join-Path $skills 'packet-progress/scripts/progress.ps1'

$script:failures = 0
$script:passes = 0
function Assert-That([bool]$Condition, [string]$Name, [string]$Detail = '') {
    if ($Condition) { $script:passes++; Write-Host "  ok    $Name" }
    else { $script:failures++; Write-Host "  FAIL  $Name" -ForegroundColor Red; if ($Detail) { Write-Host ($Detail -split "`n" | ForEach-Object { "        $_" } | Out-String) } }
}
function Invoke-Kit([string]$Script, [string[]]$KitArgs) {
    $out = & pwsh -NoProfile -File $Script @KitArgs 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out | ForEach-Object { "$_" }) -join "`n" }
}
function Write-File([string]$Path, [string]$Text) {
    $full = Join-Path $repo $Path
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
    [System.IO.File]::WriteAllText($full, $Text.Replace("`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
}
function New-Packet([string]$Id, [string]$Title, [string]$Wave, [string]$Deps, [string[]]$Owns, [string]$Lenses = 'correctness, tests', [string]$Extra = '', [string]$Locks = 'none', [string]$Priority = 'P0', [string]$Size = 'M', [string]$Touch = '') {
    $ownLines = ($Owns | ForEach-Object { "- ``$_``" }) -join "`n"
    $touchBlock = if ($Touch) { "`n## Shared touchpoints`n`n- ``$Touch``: one registration line.`n" } else { '' }
    @"
# $Id · $Title

- **Packet:** $Id · **Priority:** $Priority · **Size:** $Size · **Wave:** $Wave · **Target:** 2026-11-0$($Wave.Substring(1))
- **Depends on:** $Deps
- **Review lenses:** $Lenses
- **Locks:** $Locks
$Extra
## Goal

Build $Title.

## In scope

- $Title.

## Out of scope

- Everything else.

## Owns

$ownLines
$touchBlock
## Provides

- The $Title surface.

## Acceptance criteria

- [ ] $Title works for the empty case.
- [ ] $Title works for two items.

## Tests to run

- ``dotnet test --project tests/$($Id.Replace('-', ''))``
"@
}

$repo = Join-Path ([System.IO.Path]::GetTempPath()) ("pw-test-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
New-Item -ItemType Directory -Path $repo | Out-Null
Push-Location $repo
try {
    & git init -q -b main . | Out-Null
    & git config user.email test@example.com; & git config user.name Test; & git config commit.gpgsign false
    $cfg = Get-Content -Raw (Join-Path $kit 'templates/packet-workflow.json') | ConvertFrom-Json -AsHashtable
    $cfg.repo = 'example/sample'; $cfg.board.provider = 'local'; $cfg.review.deepPaths = '^src/Core/'
    Write-File '.github/packet-workflow.json' ($cfg | ConvertTo-Json -Depth 10)
    Write-File 'src/Api/Handlers/Get.cs' "class Get {}`n"
    Write-File 'src/App/Program.cs' "// app`n"
    Write-File 'README.md' "sample`n"
    Write-File 'docs/plan/phase-1/plan.md' @"
# Phase 1 · Sample

- **Epic:** #99

PKT-01 PKT-02 PKT-03 PKT-04 PKT-05 H-1

## Shared touchpoints

| File | Allowed edit |
| --- | --- |
| ``src/App/Program.cs`` | One line. |
"@
    Write-File 'docs/plan/phase-1/packets/PKT-01.md' (New-Packet 'PKT-01' 'Core contracts' 'W0' 'none' @('src/Core/**') 'architecture, correctness, tests')
    Write-File 'docs/plan/phase-1/packets/PKT-02.md' (New-Packet 'PKT-02' 'Persistence' 'W1' 'PKT-01' @('src/Data/**') 'data, correctness' -Locks 'migrations')
    Write-File 'docs/plan/phase-1/packets/PKT-03.md' (New-Packet 'PKT-03' 'Api endpoints' 'W1' 'PKT-01' @('src/Api/**') 'security, correctness' -Touch 'src/App/Program.cs')
    Write-File 'docs/plan/phase-1/packets/PKT-04.md' (New-Packet 'PKT-04' 'Web pages' 'W2' 'PKT-03' @('src/Web/**') 'ux, correctness' -Priority 'P1')
    Write-File 'docs/plan/phase-1/packets/PKT-05.md' (New-Packet 'PKT-05' 'Api handlers' 'W1' 'PKT-01' @('src/Api/Handlers/**', 'src/Data/Migrations/**') 'correctness' -Priority 'P2' -Extra '- **Initial status:** Backlog')
    Write-File 'docs/plan/phase-1/packets/H-1.md' @"
# H-1 · Try it by hand

- **Human task:** H-1 · **Priority:** P0 · **Target:** 2026-11-04
- **Depends on:** PKT-04

## Goal

Click through it.
"@
    & git add -A; & git commit -qm 'sample phase' | Out-Null

    Write-Host 'validate-packets'
    $r = Invoke-Kit $validate @('-Phase', 'phase-1')
    Assert-That ($r.Code -eq 1) 'overlapping packets fail validation (exit 1)' $r.Text
    Assert-That ($r.Text -match 'ERROR\s+PKT-03,PKT-05\s+PKT-03 and PKT-05 can run at the same time and both own') 'existing file owned by two concurrent packets is an ERROR tagged with both IDs' $r.Text
    Assert-That ($r.Text -match "PKT-05\s+owns paths under lock 'migrations'") 'undeclared lock is an ERROR' $r.Text
    Assert-That ($r.Text -match 'critical path \(weight \d+\): PKT-01 -> PKT-03 -> PKT-04') 'critical path is reported' $r.Text
    Assert-That ($r.Text -notmatch 'PKT-02\s+owns paths under lock') 'declared lock is accepted' $r.Text

    # Fix PKT-05: make it depend on PKT-03 and drop the migrations path.
    Write-File 'docs/plan/phase-1/packets/PKT-05.md' (New-Packet 'PKT-05' 'Api handlers' 'W2' 'PKT-03' @('src/Api/Handlers/**') 'correctness' -Priority 'P2' -Extra '- **Initial status:** Backlog')
    Write-File 'docs/plan/phase-1/packets/PKT-03.md' (New-Packet 'PKT-03' 'Api endpoints' 'W1' 'PKT-01' @('src/Api/**', '!src/Api/Handlers/**') 'security, correctness' -Touch 'src/App/Program.cs')
    $r = Invoke-Kit $validate @('-Phase', 'phase-1', '-Json')
    $v = $r.Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $v.Summary.Errors -eq 0) 'fixed plan validates' $r.Text
    Assert-That ($v.Summary.Packets -eq 5 -and $v.Summary.HumanTasks -eq 1) 'summary counts packets and human tasks' $r.Text
    # Two concurrent packets with the same directory glob collide for certain, even before any file exists.
    Write-File 'docs/plan/phase-1/packets/PKT-07.md' (New-Packet 'PKT-07' 'Web admin' 'W2' 'PKT-03' @('src/Web/Admin/**') 'correctness')
    $r = Invoke-Kit $validate @('-Phase', 'phase-1')
    Assert-That ($r.Code -eq 1 -and $r.Text -match "ERROR\s+PKT-04,PKT-07\s+PKT-04 owns 'src/Web/\*\*' and PKT-07 owns 'src/Web/Admin/\*\*'") 'a glob inside a concurrent packet''s directory is an ERROR' $r.Text
    # An exclusion of file types ('!**/*.md') doesn't carve out an area, so it can't hide that overlap.
    Write-File 'docs/plan/phase-1/packets/PKT-04.md' ((New-Packet 'PKT-04' 'Web pages' 'W2' 'PKT-03' @('src/Web/**', '!**/*.md') 'ux, correctness' -Priority 'P1'))
    $r = Invoke-Kit $validate @('-Phase', 'phase-1')
    Assert-That ($r.Code -eq 1 -and $r.Text -match "PKT-07 owns 'src/Web/Admin/\*\*'") 'a file-type exclusion does not hide a directory overlap' $r.Text
    Write-File 'docs/plan/phase-1/packets/PKT-04.md' (New-Packet 'PKT-04' 'Web pages' 'W2' 'PKT-03' @('src/Web/**') 'ux, correctness' -Priority 'P1')
    Remove-Item -LiteralPath (Join-Path $repo 'docs/plan/phase-1/packets/PKT-07.md')
    # Lower-case dependency IDs still count; a Depends on line with no ID is a problem.
    Write-File 'docs/plan/phase-1/packets/PKT-07.md' (New-Packet 'PKT-07' 'Lower deps' 'W2' 'pkt-03' @('src/Lower/**') 'correctness')
    Write-File 'docs/plan/phase-1/packets/PKT-08.md' (New-Packet 'PKT-08' 'No deps' 'W2' 'the api one' @('src/NoDeps/**') 'correctness')
    $r = Invoke-Kit $validate @('-Phase', 'phase-1', '-Json')
    $v = $r.Text | ConvertFrom-Json
    Assert-That (-not ($v.Findings | Where-Object { $_.Id -eq 'PKT-07' -and $_.Level -eq 'ERROR' }) -and ($v.Findings | Where-Object { $_.Id -eq 'PKT-08' -and $_.Text -match 'Depends on names no packet ID' })) 'dependency IDs are case-insensitive; a dependency line without IDs is an error' $r.Text
    Remove-Item -LiteralPath (Join-Path $repo 'docs/plan/phase-1/packets/PKT-07.md'), (Join-Path $repo 'docs/plan/phase-1/packets/PKT-08.md')
    # An exclusion of a directory doesn't hide a sibling glob that starts with the same letters.
    Write-File 'docs/plan/phase-1/packets/PKT-07.md' (New-Packet 'PKT-07' 'Wide' 'W2' 'PKT-03' @('src/Wide/**', '!src/Wide/Api/**') 'correctness')
    Write-File 'docs/plan/phase-1/packets/PKT-08.md' (New-Packet 'PKT-08' 'Api files' 'W2' 'PKT-03' @('src/Wide/Api*.cs') 'correctness')
    $r = Invoke-Kit $validate @('-Phase', 'phase-1')
    Assert-That ($r.Text -match "PKT-07 owns 'src/Wide/\*\*' and PKT-08 owns 'src/Wide/Api\*\.cs'") 'a directory exclusion does not hide src/Wide/Api*.cs' $r.Text
    Write-File 'docs/plan/phase-1/packets/PKT-08.md' (New-Packet 'PKT-08' 'Api dir' 'W2' 'PKT-03' @('src/Wide/Api') 'correctness')
    $r = Invoke-Kit $validate @('-Phase', 'phase-1')
    Assert-That ($r.Text -notmatch "PKT-07 owns 'src/Wide/\*\*' and PKT-08") 'an exclusion of exactly the other packet''s plain path carves it out' $r.Text
    Remove-Item -LiteralPath (Join-Path $repo 'docs/plan/phase-1/packets/PKT-07.md'), (Join-Path $repo 'docs/plan/phase-1/packets/PKT-08.md')
    # An empty packet file is reported by name, not a crash.
    Write-File 'docs/plan/phase-1/packets/PKT-09.md' ''
    $r = Invoke-Kit $validate @('-Phase', 'phase-1')
    Assert-That ($r.Code -eq 1 -and $r.Text -match 'ERROR\s+docs/plan/phase-1/packets/PKT-09\.md\s+no ID') 'an empty packet file is an ERROR naming the file' $r.Text
    Remove-Item -LiteralPath (Join-Path $repo 'docs/plan/phase-1/packets/PKT-09.md')
    & git add -A; & git commit -qm 'fix overlaps' | Out-Null

    Write-Host 'board: sync, show, next, deps'
    $r = Invoke-Kit $board @('sync', '-DryRun')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'sync: 6 created') 'dry-run sync would create six items' $r.Text
    $r = Invoke-Kit $board @('sync')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'sync: 6 created, 0 updated') 'sync creates six items' $r.Text
    Assert-That ($r.Text -match 'linked PKT-02 to 1 dependency') 'sync links dependencies' $r.Text
    $r = Invoke-Kit $board @('sync')
    Assert-That ($r.Code -eq 0 -and $r.Text -match '0 created, 0 updated, 6 unchanged') 'second sync is a no-op' $r.Text
    $r = Invoke-Kit $board @('show', '-WorkingTree')
    Assert-That ($r.Text -match 'PKT-05\s+#\d+\s+Backlog') 'Initial status Backlog is honoured' $r.Text
    $r = Invoke-Kit $board @('next', '-WorkingTree')
    Assert-That ($r.Text -match '(?m)^START\s+PKT-01') 'PKT-01 is START' $r.Text
    Assert-That ($r.Text -match '(?m)^BLOCKED PKT-02.*PKT-01 is Ready') 'PKT-02 is blocked on PKT-01' $r.Text
    $r = Invoke-Kit $board @('deps', 'PKT-03', '-WorkingTree')
    Assert-That ($r.Code -eq 1 -and $r.Text -match 'BLOCKED PKT-03') 'deps exits 1 for a blocked packet' $r.Text

    Write-Host 'board: claims'
    $r = Invoke-Kit $board @('claim', 'PKT-01', 'session-a')
    Assert-That ($r.Code -eq 0 -and $r.Text -match '^HOLD session-a') 'first claim holds' $r.Text
    $r = Invoke-Kit $board @('claim', 'PKT-01', 'session-b')
    Assert-That ($r.Code -eq 1 -and $r.Text -match '^LOST session-a') 'second session loses to the first' $r.Text
    $r = Invoke-Kit $board @('claim', 'PKT-01', 'session-a')
    Assert-That ($r.Code -eq 0 -and $r.Text -match '^HOLD session-a') 'holder refreshes its claim' $r.Text
    $r = Invoke-Kit $board @('claims', 'PKT-01')
    Assert-That (@($r.Text -split "`n" | Where-Object { $_ -match 'session-a' }).Count -eq 2 -and $r.Text -notmatch 'session-b') 'a refresh keeps the older claim until release; the lost claim is gone' $r.Text
    $r = Invoke-Kit $board @('release', 'PKT-01', 'session-a')
    Assert-That ($r.Text -match 'released 2 claim') 'release deletes all of the session''s claim comments' $r.Text
    $r = Invoke-Kit $board @('claim', 'PKT-01', 'session-b')
    Assert-That ($r.Code -eq 0) 'after release another session can hold' $r.Text
    [void](Invoke-Kit $board @('release', 'PKT-01', 'session-b'))

    Write-Host 'board: set, marker, reconcile'
    $r = Invoke-Kit $board @('set', 'PKT-01', 'Status=In progress')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'Status = In progress') 'set writes Status' $r.Text
    $r = Invoke-Kit $board @('set', 'PKT-01', 'Status=Doing')
    Assert-That ($r.Code -eq 2) 'unknown status is refused' $r.Text
    $brief = Join-Path ([System.IO.Path]::GetTempPath()) "pw-brief-$([guid]::NewGuid().ToString('n')).md"
    Set-Content -LiteralPath $brief -Value "``packet:brief base=abc1234 branch=pkt/pkt-01-core-contracts mode=START`` Implementation brief`n`nbody"
    [void](Invoke-Kit $board @('comment', 'PKT-01', $brief))
    $r = Invoke-Kit $board @('marker', 'PKT-01', 'brief', '-Json')
    $m = $r.Text | ConvertFrom-Json
    Assert-That ($m.Pairs.mode -eq 'START' -and $m.Pairs.base -eq 'abc1234') 'marker reads the brief marker' $r.Text
    [void](Invoke-Kit $board @('set', 'PKT-01', 'Closed=true'))
    $r = Invoke-Kit $board @('reconcile')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'PKT-01 #1 Status = Done \(closed\)') 'reconcile marks a closed item Done' $r.Text
    $r = Invoke-Kit $board @('help')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'claim <ID> <claim-id>') 'board help prints the command list' $r.Text
    $r = Invoke-Kit $board @('next', '-WorkingTree', '-Json')
    $n = $r.Text | ConvertFrom-Json
    Assert-That ((@($n | Where-Object { $_.Id -eq 'PKT-02' })[0].Verdict -eq 'START') -and (@($n | Where-Object { $_.Id -eq 'PKT-03' })[0].Verdict -eq 'START')) 'merging PKT-01 unblocks PKT-02 and PKT-03' $r.Text

    $r = Invoke-Kit $board @('comments', 'PKT-01', '-Json')
    $cj = $r.Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and @($cj | Where-Object { $_.Body -match 'packet:brief' }).Count -eq 1) 'board comments lists trusted comments' $r.Text

    Write-Host 'board: sync after edits'
    Write-File 'docs/plan/phase-1/packets/PKT-04.md' (New-Packet 'PKT-04' 'Web pages and nav' 'W2' 'PKT-03' @('src/Web/**') 'ux, correctness' -Priority 'P1')
    $r = Invoke-Kit $board @('sync')
    Assert-That ($r.Text -match 'updated PKT-04') 'an edited packet file updates its item' $r.Text
    $r = Invoke-Kit $board @('show', '-WorkingTree')
    Assert-That ($r.Text -match 'PKT-01\s+#1\s+Done') 'sync never changes Status' $r.Text
    & git add -A; & git commit -qm 'retitle PKT-04' | Out-Null
    Remove-Item -LiteralPath $brief
    $planPath = Join-Path $repo 'docs/plan/phase-1/plan.md'
    [System.IO.File]::WriteAllText($planPath, ((Get-Content -Raw $planPath) -replace '(?m)^# Phase 1 · Sample', '# Phase 1 · Renamed'), [System.Text.UTF8Encoding]::new($false))
    $r = Invoke-Kit $board @('sync')
    $moved = (Invoke-Kit $board @('get', 'PKT-02')).Text | ConvertFrom-Json
    Assert-That ($r.Text -match 'sync: 0 created, 6 updated' -and $moved.Milestone -eq 'Phase 1 · Renamed') 'a renamed phase heading moves every item to the new milestone' $r.Text
    & git checkout -q -- docs/plan/phase-1/plan.md
    $r = Invoke-Kit $board @('sync')
    Assert-That ($r.Text -match 'sync: 0 created, 6 updated') 'and back' $r.Text

    # board reads the config as merged on origin/main: a branch can't switch the board or the trust list.
    $bare = Join-Path ([System.IO.Path]::GetTempPath()) ("pw-origin-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
    & git init -q --bare $bare; & git remote add origin $bare; & git push -q origin main 2>$null; & git fetch -q origin; & git remote set-head origin main
    $cfgText = Get-Content -Raw (Join-Path $repo '.github/packet-workflow.json')
    Write-File '.github/packet-workflow.json' ($cfgText -replace '"provider": "local"', '"provider": "github-issues"')
    $r = Invoke-Kit $board @('show', '-WorkingTree')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'board: local') 'board uses the config on origin/main, not a local edit' $r.Text
    Write-File '.github/packet-workflow.json' (($cfgText -replace '"provider": "local"', '"provider": "github-issues"') -replace '"defaultBranch": "main"', '"defaultBranch": "nope"')
    $r = Invoke-Kit $board @('show', '-WorkingTree')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'board: local') 'a local defaultBranch edit cannot redirect board to another config' $r.Text
    Write-File '.github/packet-workflow.json' $cfgText
    & git remote remove origin; Remove-Item -Recurse -Force -LiteralPath $bare

    Write-Host 'review-scope'
    & git switch -q -c pkt/pkt-03-api-endpoints
    Write-File 'src/Api/Orders.cs' (("public class Orders {`n" + (1..20 | ForEach-Object { "  public int M$_(int x) { if (x > $_) { return x; } return 0; }`n" }) + "}`n") -join '')
    Write-File 'src/Api/Auth/TokenCheck.cs' "class TokenCheck { static readonly SemaphoreSlim Gate = new(1); }`n"
    & git add -A; & git commit -qm 'api' | Out-Null
    $apiSha = (& git rev-parse HEAD).Trim()
    $r = Invoke-Kit $reviewScope @('-Base', 'main', '-Packet', 'PKT-03', '-Json')
    $s = $r.Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $s.Tier -eq 3) 'auth path and a semaphore raise the tier to 3' $r.Text
    Assert-That ($s.Agent -eq 'packet-reviewer-deep') 'tier 3 names the deep reviewer' $r.Text
    Assert-That (($s.Lenses -contains 'security') -and ($s.Lenses -contains 'concurrency') -and ($s.Lenses -contains 'correctness')) 'lenses: packet lenses plus security and concurrency from the diff' $r.Text
    Assert-That ($s.Runs.Count -eq $s.Lenses.Count -and $s.Pairs[0][0] -eq $s.Lenses[0] -and $s.Settings.MaxRounds -eq 3 -and $s.Settings.ShouldFixPassFromRound -eq 3 -and $s.Settings.LensesPerReviewer -eq 1) 'by default one lens per reviewer run, and should-fix-only rounds pass only in the last round' $r.Text
    $altCfg = Join-Path ([System.IO.Path]::GetTempPath()) "pw-cfg-$([guid]::NewGuid().ToString('n')).json"
    $alt = $cfg.Clone(); $alt.review = $cfg.review.Clone(); $alt.review.lensesPerReviewer = 2; $alt.review.shouldFixPassFromRound = 2
    Set-Content -LiteralPath $altCfg -Value ($alt | ConvertTo-Json -Depth 10)
    $r = Invoke-Kit $reviewScope @('-Base', 'main', '-Packet', 'PKT-03', '-Json', '-ConfigPath', $altCfg)
    $s = $r.Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $s.Tier -eq 3 -and (($s.Lenses) -join ',') -eq 'security,concurrency,correctness' -and $s.Runs.Count -eq 2 -and (($s.Runs[0]) -join '+') -eq 'security+concurrency' -and (($s.Pairs[0]) -join ',') -eq 'security+concurrency,correctness' -and $s.Settings.ShouldFixPassFromRound -eq 2) 'lensesPerReviewer 2 groups neighbouring lenses into runs, keeps every lens and the tier' $r.Text
    $alt.review.lensesPerReviewer = 4
    Set-Content -LiteralPath $altCfg -Value ($alt | ConvertTo-Json -Depth 10)
    $r = Invoke-Kit $reviewScope @('-Base', 'main', '-Packet', 'PKT-03', '-ConfigPath', $altCfg)
    Assert-That ($r.Code -eq 2 -and $r.Text -match 'lensesPerReviewer must be 1, 2 or 3') 'more than three lenses per reviewer run is refused' $r.Text
    $alt.review.lensesPerReviewer = 1; $alt.review.shouldFixPassFromRound = 9
    Set-Content -LiteralPath $altCfg -Value ($alt | ConvertTo-Json -Depth 10)
    $r = Invoke-Kit $reviewScope @('-Base', 'main', '-Packet', 'PKT-03', '-Json', '-ConfigPath', $altCfg)
    $s = $r.Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $s.Settings.ShouldFixPassFromRound -eq 3) 'a shouldFixPassFromRound past maxRounds means the last round' $r.Text
    $alt.review.shouldFixPassFromRound = 0
    Set-Content -LiteralPath $altCfg -Value ($alt | ConvertTo-Json -Depth 10)
    $r = Invoke-Kit $reviewScope @('-Base', 'main', '-Packet', 'PKT-03', '-ConfigPath', $altCfg)
    Assert-That ($r.Code -eq 2 -and $r.Text -match 'shouldFixPassFromRound must be a round number') 'round 0 is refused' $r.Text
    # The template leaves shouldFixPassFromRound null, so it follows maxRounds.
    $alt.review.lensesPerReviewer = 1; $alt.review.shouldFixPassFromRound = $null; $alt.review.maxRounds = 4
    Set-Content -LiteralPath $altCfg -Value ($alt | ConvertTo-Json -Depth 10)
    $r = Invoke-Kit $reviewScope @('-Base', 'main', '-Packet', 'PKT-03', '-Json', '-ConfigPath', $altCfg)
    $s = $r.Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $s.Settings.MaxRounds -eq 4 -and $s.Settings.ShouldFixPassFromRound -eq 4) 'a null shouldFixPassFromRound (the template''s) follows maxRounds' $r.Text
    # Existing installs have no lensesPerReviewer or shouldFixPassFromRound: one lens per run, and only the last round passes on should-fix.
    $alt.review.Remove('lensesPerReviewer'); $alt.review.Remove('shouldFixPassFromRound'); $alt.review.maxRounds = 5
    Set-Content -LiteralPath $altCfg -Value ($alt | ConvertTo-Json -Depth 10)
    $r = Invoke-Kit $reviewScope @('-Base', 'main', '-Packet', 'PKT-03', '-Json', '-ConfigPath', $altCfg)
    $s = $r.Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $s.Settings.MaxRounds -eq 5 -and $s.Settings.ShouldFixPassFromRound -eq 5 -and $s.Settings.LensesPerReviewer -eq 1 -and $s.Runs.Count -eq $s.Lenses.Count) 'a config without the new keys keeps the old panel: should-fix passes only in the last round, one lens per run' $r.Text
    $alt.review.maxRounds = '3'
    Set-Content -LiteralPath $altCfg -Value ($alt | ConvertTo-Json -Depth 10)
    $r = Invoke-Kit $reviewScope @('-Base', 'main', '-Packet', 'PKT-03', '-Json', '-ConfigPath', $altCfg)
    $s = $r.Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $s.Settings.MaxRounds -eq 3 -and $s.Settings.ShouldFixPassFromRound -eq 3) 'a quoted whole number still counts' $r.Text
    Remove-Item -LiteralPath $altCfg
    Write-File 'docs/notes.md' "a note`n"
    & git add -A; & git commit -qm 'note' | Out-Null
    $r = Invoke-Kit $reviewScope @('-Base', 'HEAD~1', '-Json')
    $s = $r.Text | ConvertFrom-Json
    Assert-That ($s.Tier -eq 1) 'docs-only diff is tier 1' $r.Text
    $r = Invoke-Kit $reviewScope @('-Base', 'main', '-Packet', 'PKT-03', '-Since', $apiSha, '-Confirmed', 'security,concurrency', '-PreviousTier', '3', '-FixedConfirmed', '-Json')
    $s = $r.Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $s.Tier -eq 4 -and ($s.Lenses -contains 'security') -and ($s.Lenses -contains 'concurrency') -and -not ($s.Lenses | Where-Object { $_ -match ',' })) 'round 2: comma-separated -Confirmed splits, and a fixed round goes up a tier' $r.Text
    $r = Invoke-Kit $reviewScope @('-Base', 'main', '-Packet', 'PKT-03', '-Since', $apiSha, '-Confirmed', '-', '-PreviousTier', '3', '-Json')
    $s = $r.Text | ConvertFrom-Json
    Assert-That (-not ($s.Lenses -contains '-') -and $s.Lenses.Count -ge 1) 'round 2 after a pass: "-" is not a lens, and a round never has none' $r.Text
    Write-File 'src/Core/Clock.cs' "class Clock {}`n"
    $cfgText = Get-Content -Raw (Join-Path $repo '.github/packet-workflow.json')
    Write-File '.github/packet-workflow.json' ($cfgText -replace '"deepPaths": "\^src/Core/"', '"deepPaths": ""')
    & git add -A; & git commit -qm 'core, and a config edit that drops the deep path' | Out-Null
    $r = Invoke-Kit $reviewScope @('-Base', 'HEAD~1', '-Json')
    $s = $r.Text | ConvertFrom-Json
    Assert-That ($s.Tier -eq 4 -and ($s.Reasons -join ' ') -match 'project deep path') 'the base config decides: a branch dropping deepPaths still gets the raise (and the config edit is machinery)' $r.Text
    Write-File '.github/packet-workflow.json' $cfgText
    & git add -A; & git commit -qm 'restore config' | Out-Null
    # review-tier.sh parity: async code is concurrency (tier 3); a NUL byte can't hide a file's lines;
    # a project lens is review machinery (tier 4).
    Write-File 'src/Api/Svc.cs' "class Svc {`n  async Task Run() { await Task.Delay(10); }`n}`n"
    & git add -A; & git commit -qm 'async' | Out-Null
    $r = Invoke-Kit $reviewScope @('-Base', 'HEAD~1', '-Json'); $s = $r.Text | ConvertFrom-Json
    Assert-That ($s.Tier -eq 3 -and ($s.Reasons -join ' ') -match 'concurrency in added lines') 'async/await raises the tier to 3, as review-tier.sh does' $r.Text
    $js = "// `0`n" + ((1..1200 | ForEach-Object { "if (x) { save(); }" }) -join "`n") + "`n"
    [System.IO.File]::WriteAllText((Join-Path $repo 'src/Api/app.js'), $js)
    & git add -A; & git commit -qm 'nul' | Out-Null
    $r = Invoke-Kit $reviewScope @('-Base', 'HEAD~1', '-Json'); $s = $r.Text | ConvertFrom-Json
    Assert-That ($s.Tier -eq 4 -and $s.Lines -ge 1200) 'a NUL byte does not hide 1200 lines (read with NULs dropped)' $r.Text
    Write-File '.github/packet-lenses/data.md' "# Lens: data`n`nblocking: nothing`n"
    & git add -A; & git commit -qm 'lens' | Out-Null
    $r = Invoke-Kit $reviewScope @('-Base', 'HEAD~1', '-Json'); $s = $r.Text | ConvertFrom-Json
    Assert-That ($s.Tier -eq 4 -and ($s.Reasons -join ' ') -match 'review machinery') 'a project lens edit is review machinery (tier 4)' $r.Text
    $cfgText = Get-Content -Raw (Join-Path $repo '.github/packet-workflow.json')
    Write-File '.github/packet-workflow.json' ($cfgText -replace '"lenses": "\.github/packet-lenses"', '"lenses": "./review/lenses"')
    & git add -A; & git commit -qm 'move lenses' | Out-Null
    Write-File 'review/lenses/correctness.md' "# Lens: correctness`n`nblocking: nothing`n"
    & git add -A; & git commit -qm 'lens in configured dir' | Out-Null
    $r = Invoke-Kit $reviewScope @('-Base', 'HEAD~1', '-Json'); $s = $r.Text | ConvertFrom-Json
    Assert-That ($s.Tier -eq 4 -and ($s.Reasons -join ' ') -match 'review machinery path: review/lenses/') 'a lens edit under a configured paths.lenses is review machinery too' $r.Text
    & git reset -q --hard HEAD~5

    Write-Host 'check-scope'
    $r = Invoke-Kit $checkScope @('-Packet', 'PKT-03', '-Base', 'main')
    Assert-That ($r.Code -eq 1 -and $r.Text -match 'OUTSIDE\s+src/Core/Clock\.cs' -and $r.Text -match 'OUTSIDE\s+docs/notes\.md') 'paths outside Owns are reported' $r.Text
    Assert-That ($r.Text -notmatch 'OUTSIDE\s+src/Api/Orders\.cs') 'owned paths pass' $r.Text
    & git reset -q --hard HEAD~3
    $r = Invoke-Kit $checkScope @('-Packet', 'PKT-03', '-Base', 'main')
    Assert-That ($r.Code -eq 0) 'a diff inside Owns passes' $r.Text
    Write-File 'src/Api/Leftover.cs' "class Leftover {}`n"
    $r = Invoke-Kit $checkScope @('-Packet', 'PKT-03', '-Base', 'main')
    Assert-That ($r.Code -eq 1 -and $r.Text -match 'DIRTY\s+src/Api/Leftover\.cs') 'uncommitted changes fail the scope check' $r.Text
    Remove-Item -LiteralPath (Join-Path $repo 'src/Api/Leftover.cs')
    $trustTest = Join-Path ([System.IO.Path]::GetTempPath()) "pw-trust-$([guid]::NewGuid().ToString('n')).ps1"
    Set-Content -LiteralPath $trustTest -Value @"
. '$((Join-Path $skills 'packet-board/scripts/PacketWorkflow.ps1').Replace("'", "''"))'
function Get-ProvCurrentUser { 'owner' }
function Get-ProvComments { param(`$Ref) @(
    [pscustomobject]@{ Id = 1; CreatedAt = [DateTimeOffset]'2026-01-01T00:00:00Z'; Body = '``packet:claim mallory-1`` x'; Author = 'mallory' },
    [pscustomobject]@{ Id = 2; CreatedAt = [DateTimeOffset]'2026-01-01T00:00:05Z'; Body = '``packet:claim owner-1`` x'; Author = 'owner' },
    [pscustomobject]@{ Id = 3; CreatedAt = [DateTimeOffset]'2026-01-01T00:00:06Z'; Body = '``packet:claim teammate-1`` x'; Author = 'Teammate' }) }
`$script:PwConfig = @{ trustedAuthors = @('teammate') }
(Get-PwClaimComments -Ref '1' | ForEach-Object ClaimId) -join ','
"@
    $r = Invoke-Kit $trustTest @()
    Assert-That ($r.Text.Trim() -eq 'owner-1,teammate-1') 'claims from untrusted authors are ignored; trustedAuthors count, case-insensitively' $r.Text
    Remove-Item -LiteralPath $trustTest
    $unitTest = Join-Path ([System.IO.Path]::GetTempPath()) "pw-unit-$([guid]::NewGuid().ToString('n')).ps1"
    $phaseRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pw-phases-$([guid]::NewGuid().ToString('n'))"
    $headings = [ordered]@{ a = "# TextKit (e2e): plan`n`n- **Epic:** #0`n"; b = "# Disaster recovery plan`n`n- **Epic:** #12`n"; c = "# Office floor-plan`n"; d = "# Migration-Plan`n"; e = "# Checkout — Plan`n" }
    foreach ($k in $headings.Keys) {
        New-Item -ItemType Directory -Force -Path (Join-Path $phaseRoot "docs/plan/$k") | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $phaseRoot "docs/plan/$k/plan.md"), $headings[$k], [System.Text.UTF8Encoding]::new($false))
    }
    Set-Content -LiteralPath $unitTest -Value @"
. '$((Join-Path $skills 'packet-board/scripts/PacketWorkflow.ps1').Replace("'", "''"))'
`$cfg = @{ paths = @{ plans = 'docs/plan' }; repoRoot = '$($phaseRoot.Replace("'", "''"))' }
`$a = Get-PwPhaseInfo -Config `$cfg -Phase 'a'; `$b = Get-PwPhaseInfo -Config `$cfg -Phase 'b'
"title-a=`$(`$a.Title)|epic-a=`$(`$a.Epic)|title-b=`$(`$b.Title)|epic-b=`$(`$b.Epic)"
"titles=" + ((@('c', 'd', 'e') | ForEach-Object { (Get-PwPhaseInfo -Config `$cfg -Phase `$_).Title }) -join '|')
. '$((Join-Path $skills 'packet-board/scripts/providers/github-common.ps1').Replace("'", "''"))'
function Confirm-PwGhLabel { param(`$Config, `$Name, `$Color, `$Description, [switch]`$DryRun) `$true }
"labels=" + ((Initialize-PwGhLabels -Config @{ labels = @{ packet = 'packet'; human = 'human-task'; needsHuman = 'needs-human'; followUp = 'follow-up' } } -Keys 'needsHuman', 'followUp') -join ',')
"claim=`$(New-PwClaimId)"
"host=`$(([System.Net.Dns]::GetHostName() -split '\.')[0])"
# Credit estimates: stage 5's PKT-1 (S, three tier-4 rounds of 4, 3 and 1 lenses, two fix rounds).
`$ec = Merge-PwHashtable `$script:Defaults @{}
`$s5 = @(
    [pscustomobject]@{ Kind = 'round'; Round = 1; Tier = '4'; Lenses = 'ops,architecture,correctness,tests'; Runs = `$null; Outcome = 'fix'; CreatedAt = '2026-10-19T21:20:00Z' },
    [pscustomobject]@{ Kind = 'round'; Round = 2; Tier = '4'; Lenses = 'ops,correctness,tests'; Runs = `$null; Outcome = 'fix'; CreatedAt = '2026-10-19T21:40:00Z' },
    [pscustomobject]@{ Kind = 'settle-request'; Round = 2; Tier = `$null; Lenses = `$null; Runs = `$null; Outcome = 'settle'; CreatedAt = '2026-10-19T21:45:00Z' },
    [pscustomobject]@{ Kind = 'round'; Round = 3; Tier = '4'; Lenses = 'tests'; Outcome = 'pass'; CreatedAt = '2026-10-19T21:55:00Z' })
`$e = Get-PwCreditEstimate -Config `$ec -Size 'S' -Rounds `$s5
"estimate=`$(`$e.Credits)|runs=`$(`$e.ReviewerRuns)|impl=`$(`$e.ImplementerRuns)|rounds=`$(`$e.Rounds.Count)"
`$g = Get-PwCreditEstimate -Config `$ec -Size 'S' -Rounds @([pscustomobject]@{ Round = 1; Tier = '4'; Lenses = 'ops,architecture,correctness,tests'; Runs = '2'; Outcome = 'pass'; CreatedAt = `$null })
"grouped=`$(`$g.Credits)|runs=`$(`$g.ReviewerRuns)"
`$ec.budget = Merge-PwHashtable `$ec.budget @{ monthlyCredits = 12500 }
`$p2 = @(
    @{ Kind = 'round'; Round = 1; Tier = '3'; Lenses = 'correctness,tests'; Outcome = 'fix'; CreatedAt = '2026-09-30T23:00:00Z' },
    @{ Kind = 'round'; Round = 2; Tier = '4'; Lenses = 'tests'; Outcome = 'fix'; CreatedAt = '2026-10-01T01:00:00Z' })
`$sum = Get-PwCreditSummary -Config `$ec -Today ([DateTime]'2026-10-20') -Packets @(
    [pscustomobject]@{ Id = 'PKT-01'; Size = 'S'; Pr = 7; Rounds = `$s5 },
    [pscustomobject]@{ Id = 'PKT-02'; Size = 'M'; Pr = 8; Rounds = `$p2 },
    [pscustomobject]@{ Id = 'PKT-03'; Size = 'L'; Pr = 9; Rounds = @() })
"summary=`$(`$sum.Total)|avg=`$(`$sum.PerFinishedPacket)|month=`$(`$sum.Month):`$(`$sum.ThisMonth)|left=`$(`$sum.Left)|more=`$(`$sum.PacketsLeft)|finished=`$((`$sum.Packets | ForEach-Object Finished) -join ',')|counted=`$(`$sum.Packets.Count)"
`$bad = Merge-PwHashtable `$script:Defaults @{ budget = @{ creditsPerRun = @{ reviewerByTier = @{ M = @(30, 70, 160) } } } }
try { [void](Get-PwCreditEstimate -Config `$bad -Size 'M' -Rounds `$p2); 'budget-check=none' } catch { "budget-check=`$(`$_.Exception.Message)" }
`$none = Get-PwCreditSummary -Config `$ec -Packets @()
`$lastMonth = Get-PwCreditSummary -Config `$ec -Today ([DateTime]'2026-11-03') -Packets @([pscustomobject]@{ Id = 'PKT-01'; Size = 'S'; Pr = 7; Rounds = `$s5 })
"empty=`$(`$none.Total)/`$(`$none.Packets.Count)|november=`$(`$lastMonth.Month):`$(`$lastMonth.ThisMonth)|left=`$(`$lastMonth.Left)"
# The review table is copied before Get-PwConfig fills it in, so the defaults stay as they were.
`$cfgFile = [System.IO.Path]::GetTempFileName()
Set-Content -LiteralPath `$cfgFile -Value '{ "repo": "example/sample" }'
`$c1 = Get-PwConfig -Path `$cfgFile; Remove-Item -LiteralPath `$cfgFile
"defaults-untouched=`$(-not `$script:Defaults.review.Contains('shouldFixPassFromRound'))|first=`$(`$c1.review.shouldFixPassFromRound)"
# The trusted round reader (board rounds, progress -Credits) against stubbed GitHub calls.
. '$((Join-Path $skills 'packet-board/scripts/providers/github-common.ps1').Replace("'", "''"))'
function Invoke-PwGh { 'owner' }
function Invoke-PwGhPages { param(`$Path) @(
    @{ id = 6; user = @{ login = 'owner' }; body = '``packet:round 2 head=bbb tier=4 lenses=tests runs=1 confirmed=- outcome=pass``'; created_at = '2026-10-02T00:00:00Z'; html_url = 'u6' },
    @{ id = 1; user = @{ login = 'mallory' }; body = '``packet:round 9 head=zzz tier=1 lenses=x confirmed=- outcome=pass``'; created_at = '2026-10-01T00:00:00Z'; html_url = 'u1' },
    @{ id = 3; user = @{ login = 'Owner' }; body = '``packet:round 1 head=aaa tier=3 lenses=a,b confirmed=a outcome=fix``'; created_at = '2026-10-01T01:00:00Z'; html_url = 'u3' },
    @{ id = 5; user = @{ login = 'owner' }; body = '``packet:settle head=aaa``'; created_at = '2026-10-01T02:00:00Z'; html_url = 'u5' },
    @{ id = 7; user = @{ login = 'teammate' }; body = '``packet:settle-check head=bbb``'; created_at = '2026-10-02T01:00:00Z'; html_url = 'u7' }) }
`$rr = Get-PwGhRounds -Config @{ repo = 'example/sample'; trustedAuthors = @('Teammate') } -Pr '7'
"rounds=" + ((`$rr | ForEach-Object { "`$(`$_.Kind):`$(`$_.Round):`$(`$_.Runs):`$(`$_.Consumed)" }) -join ',')
"@
    $r = Invoke-Kit $unitTest @()
    Assert-That ($r.Text -match 'title-a=TextKit \(e2e\)\|epic-a=\|title-b=Disaster recovery plan\|epic-b=#12') 'the phase title drops a ": plan" suffix only; the template''s #0 is no epic' $r.Text
    Assert-That ($r.Text -match 'titles=Office floor-plan\|Migration-Plan\|Checkout(\r?\n|$)') 'a hyphenated word ending in plan is kept; a spaced dash before Plan is a suffix' $r.Text
    Assert-That ($r.Text -match 'labels=needs-human,follow-up') 'the follow-up labels can be set up on their own (Azure Boards setup)' $r.Text
    $claimId = if ($r.Text -match 'claim=(\S+)') { $Matches[1] } else { '' }
    $hostName = if ($r.Text -match 'host=(\S+)') { $Matches[1] } else { '' }
    Assert-That ($claimId -match '^session-[0-9a-f]{8}-\d{8}T\d{6}Z-\d{5}$' -and (-not $hostName -or $claimId -notmatch [regex]::Escape($hostName))) 'a claim id carries a hash of the machine, not its host name' $r.Text
    # Base 50 + 105. Rounds: 300 + 4×35 + 4×195 + 40 = 1260; 300 + 3×35 + 0.85×3×195 + 40 = 942; 300 + 35 + 0.85×195 = 501.
    Assert-That ($r.Text -match 'estimate=2858\|runs=8\|impl=3\|rounds=3') 'credit estimate for stage 5: settle rows ignored, a row without Runs is one run per lens' $r.Text
    Assert-That ($r.Text -match 'grouped=1071\|runs=2') 'two runs of two lenses count 2.8 runs' $r.Text
    # PKT-02 (M): 250 base and 775 in September (its round 1), 330 + 35 + 0.85×280 + 55 = 658 in October; only PKT-01 has finished.
    Assert-That ($r.Text -match 'summary=4541\|avg=2858\|month=2026-10:3516\|left=8984\|more=3\|finished=True,False\|counted=2') 'credit summary: month by round date, average over finished packets, packets with no round left out' $r.Text
    Assert-That ($r.Text -match 'budget-check=config: budget\.creditsPerRun\.reviewerByTier\.M must list four numbers') 'a malformed credits table stops the estimate with a clear message' $r.Text
    Assert-That ($r.Text -match 'empty=0/0\|november=2026-11:0\|left=12500') 'a phase with no round reports, and one whose rounds are all last month, are estimated without failing' $r.Text
    Assert-That ($r.Text -match 'defaults-untouched=True\|first=3') 'Get-PwConfig fills in shouldFixPassFromRound on a copy, not on the shared defaults' $r.Text
    Assert-That ($r.Text -match 'rounds=round:1::False,settle-request:1::True,round:2:1:False,settle-check:2::False(\r?\n|$)') 'the trusted round reader: untrusted rounds dropped, comment order, settle rounds, Consumed, runs=' $r.Text
    Remove-Item -LiteralPath $unitTest; Remove-Item -Recurse -Force -LiteralPath $phaseRoot
    & git switch -q main

    Write-Host 'progress'
    $r = Invoke-Kit $progress @('-WorkingTree')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'Done\s+1') 'progress counts Done' $r.Text
    Assert-That ($r.Text -match 'PKT-03.*unblocks') 'progress reports merge leverage' $r.Text
    Assert-That ($r.Text -match 'Critical path left \(weight \d+\): PKT-03 -> PKT-04 -> H-1') 'critical path leaves out Done packets' $r.Text
    $r = Invoke-Kit $progress @('-WorkingTree', '-Json')
    $pj = $r.Text | ConvertFrom-Json
    Assert-That ($pj.Totals.Packets -eq 5 -and $pj.Totals.DonePercent -gt 0) 'progress JSON totals' $r.Text
    # PKT-06 (P0) depends on PKT-05 (P2, Backlog): an inversion and a packet waiting on Backlog.
    Write-File 'docs/plan/phase-1/packets/PKT-06.md' (New-Packet 'PKT-06' 'Checkout' 'W3' 'PKT-05' @('src/Checkout/**') 'correctness')
    [void](Invoke-Kit $board @('sync'))
    $r = Invoke-Kit $progress @('-WorkingTree', '-Json')
    $pj = $r.Text | ConvertFrom-Json
    Assert-That ((@($pj.Inversions | Where-Object { $_.Id -eq 'PKT-06' -and $_.DependsOn -eq 'PKT-05' }).Count -eq 1)) 'priority inversion is reported' $r.Text
    Assert-That ((@($pj.WaitingOnBacklog | Where-Object { $_.Id -eq 'PKT-06' }).Count -eq 1) -and $pj.Health -ne 'on track') 'waiting on Backlog is reported and lowers health' $r.Text

    # progress -Credits end to end, with a fake gh on PATH: PR lookup by branch (newest wins), trusted
    # round markers only, the month by UTC report date. Packets are M; see Get-PwCreditEstimate.
    $fakeBin = Join-Path ([System.IO.Path]::GetTempPath()) ("pw-gh-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
    New-Item -ItemType Directory -Path $fakeBin | Out-Null
    $mk = { param($id, $who, $marker, $at) @{ id = $id; user = @{ login = $who }; body = "``packet:$marker`` report"; created_at = $at; html_url = "u$id" } }
    $ghData = @{
        prs = @(@{ number = 10; headRefName = 'pkt/pkt-01-old-attempt' }, @{ number = 11; headRefName = 'pkt/pkt-01-core-contracts' }, @{ number = 12; headRefName = 'pkt/pkt-02-persistence' })
        comments = @{
            '10' = @(& $mk 9 'owner' 'round 1 head=old tier=4 lenses=a,b,c,d,e confirmed=- outcome=pass' '2026-09-01T00:00:00Z')
            '11' = @((& $mk 1 'owner' 'round 1 head=a tier=3 lenses=architecture,correctness,tests confirmed=tests outcome=fix' '2026-09-30T23:30:00Z'),
                (& $mk 2 'mallory' 'round 2 head=z tier=1 lenses=x confirmed=- outcome=pass' '2026-10-01T00:00:00Z'),
                (& $mk 3 'owner' 'round 2 head=b tier=4 lenses=tests confirmed=- outcome=pass' '2026-10-01T00:30:00Z'))
            '12' = @(& $mk 4 'owner' 'round 1 head=c tier=2 lenses=data,correctness runs=1 confirmed=data outcome=fix' '2026-10-01T02:00:00Z')
        }
    }
    Set-Content -LiteralPath (Join-Path $fakeBin 'gh-data.json') -Value ($ghData | ConvertTo-Json -Depth 8)
    Set-Content -LiteralPath (Join-Path $fakeBin 'gh.ps1') -Value @'
$data = Get-Content -Raw (Join-Path $PSScriptRoot 'gh-data.json') | ConvertFrom-Json -AsHashtable
$a = @($args)
if ($a[0] -eq 'pr' -and $a[1] -eq 'list') { ConvertTo-Json -InputObject @($data.prs) -Depth 5; exit 0 }
if ($a[0] -eq 'api' -and $a -contains 'user') { 'owner'; exit 0 }
$path = @($a | Where-Object { "$_" -match '/issues/\d+/comments' })[0]
if ($a[0] -eq 'api' -and $path -match '/issues/(\d+)/comments') { ConvertTo-Json -InputObject @(, @($data.comments[$Matches[1]])) -Depth 6; exit 0 }
[Console]::Error.WriteLine("fake gh: unexpected call: $($a -join ' ')"); exit 1
'@
    if ($IsWindows) { Set-Content -LiteralPath (Join-Path $fakeBin 'gh.cmd') -Value "@pwsh -NoProfile -File `"%~dp0gh.ps1`" %*" }
    else { Set-Content -LiteralPath (Join-Path $fakeBin 'gh') -Value "#!/bin/sh`nexec pwsh -NoProfile -File `"`$(dirname `"`$0`")/gh.ps1`" `"`$@`""; & chmod +x (Join-Path $fakeBin 'gh') }
    $oldPath = $env:PATH
    $env:PATH = $fakeBin + [System.IO.Path]::PathSeparator + $env:PATH
    try {
        $r = Invoke-Kit $progress @('-WorkingTree', '-Credits', '-Today', '2026-10-20', '-Json')
        $c = ($r.Text | ConvertFrom-Json).Credits
        $line = (@($c.Packets) | ForEach-Object { "$($_.Id):$($_.Pr):$($_.Credits):$($_.Finished)" }) -join ','
        Assert-That ($r.Code -eq 0 -and $line -eq 'PKT-01:11:1823:True,PKT-02:12:768:False' -and $c.Total -eq 2591 -and $c.PerFinishedPacket -eq 1823 -and $c.Month -eq '2026-10' -and $c.ThisMonth -eq 1371) 'progress -Credits: newest PR per packet, untrusted rounds dropped, credits per packet, phase and month' $r.Text
        $r = Invoke-Kit $progress @('-WorkingTree', '-Credits', '-Today', '2026-09-30', '-Json')
        $c = ($r.Text | ConvertFrom-Json).Credits
        Assert-That ($r.Code -eq 0 -and $c.Month -eq '2026-09' -and $c.ThisMonth -eq 1220) 'a round reported at 23:30 UTC on 30 September counts in September, with its packet''s base' $r.Text
        $r = Invoke-Kit $progress @('-WorkingTree', '-Credits')
        Assert-That ($r.Code -eq 0 -and $r.Text -match 'PKT-02\s+M\s+PR #12\s+1 round\(s\), 1 reviewer run\(s\), 2 implementer run\(s\)\s+768\s+\(in review\)' -and $r.Text -match "phase 2,591 · 1,823 per finished packet · $([DateTime]::UtcNow.ToString('yyyy-MM')):") 'progress -Credits text: the estimate per packet and the UTC month by default' $r.Text
    }
    finally { $env:PATH = $oldPath; Remove-Item -Recurse -Force -LiteralPath $fakeBin }
}
finally {
    Pop-Location
    if ($Keep) { Write-Host "kept $repo" } else { Remove-Item -Recurse -Force -LiteralPath $repo }
}
Write-Host 'check-scope after merging the default branch'
# Two packets run in parallel; PKT-01 merges first, PKT-02 merges the default branch into its branch.
# The files PKT-01 landed must not count as PKT-02's, but an edit or a revert of them in the merge must.
$mergeRepo = Join-Path ([System.IO.Path]::GetTempPath()) ("pw-merge-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
$originRepo = "$mergeRepo-origin.git"
New-Item -ItemType Directory -Path $mergeRepo | Out-Null
Push-Location $mergeRepo
try {
    function Write-MergeFile([string]$Path, [string]$Text) {
        $full = Join-Path $mergeRepo $Path
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
        [System.IO.File]::WriteAllText($full, $Text, [System.Text.UTF8Encoding]::new($false))
    }
    function Invoke-Q { $out = & git @args 2>&1; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' '): $out" } }
    Invoke-Q init -q -b main .
    Invoke-Q config user.email test@example.com; Invoke-Q config user.name Test; Invoke-Q config commit.gpgsign false
    $mcfg = Get-Content -Raw (Join-Path $kit 'templates/packet-workflow.json') | ConvertFrom-Json -AsHashtable
    $mcfg.repo = 'example/merge'; $mcfg.board.provider = 'local'
    Write-MergeFile '.github/packet-workflow.json' ($mcfg | ConvertTo-Json -Depth 10)
    Write-MergeFile 'src/App.ps1' "# loader`n"
    Write-MergeFile 'docs/plan/p/plan.md' "# P`n`n## Shared touchpoints`n`n| File | Allowed edit |`n| --- | --- |`n| ``src/App.ps1`` | One line. |`n"
    Write-MergeFile 'docs/plan/p/packets/PKT-01.md' (New-Packet 'PKT-01' 'Alpha' 'W0' 'none' @('src/A/**') -Touch 'src/App.ps1')
    Write-MergeFile 'docs/plan/p/packets/PKT-02.md' (New-Packet 'PKT-02' 'Beta' 'W0' 'none' @('src/B/**') -Touch 'src/App.ps1')
    Write-MergeFile 'docs/plan/p/packets/PKT-03.md' (New-Packet 'PKT-03' 'Gamma' 'W1' 'PKT-02' @('src/C/**'))
    Invoke-Q add -A; Invoke-Q commit -qm 'phase p'
    $b0 = (& git rev-parse HEAD).Trim()
    Invoke-Q init -q --bare -b main $originRepo
    Invoke-Q remote add origin $originRepo
    Invoke-Q push -q origin main
    Invoke-Q remote set-head origin main
    Invoke-Q switch -q -c pkt/pkt-01-alpha
    Write-MergeFile 'src/A/a.ps1' "function A {}`n"; Write-MergeFile 'src/App.ps1' "# loader`n. `$PSScriptRoot/A/a.ps1`n"
    Invoke-Q add -A; Invoke-Q commit -qm 'PKT-01'
    Invoke-Q switch -q -c pkt/pkt-02-beta $b0
    Write-MergeFile 'src/B/b.ps1' "function B {}`n"; Write-MergeFile 'src/App.ps1' "# loader`n. `$PSScriptRoot/B/b.ps1`n"
    Invoke-Q add -A; Invoke-Q commit -qm 'PKT-02'
    $pkt2Head = (& git rev-parse HEAD).Trim()
    Invoke-Q switch -q main; Invoke-Q merge -q --no-ff pkt/pkt-01-alpha -m 'Merge PKT-01'; Invoke-Q push -q origin main
    Invoke-Q fetch -q origin
    # The conflict in the loader, resolved with both lines.
    Invoke-Q switch -q pkt/pkt-02-beta
    & git merge -q origin/main -m 'Merge main' 2>&1 | Out-Null
    Write-MergeFile 'src/App.ps1' "# loader`n. `$PSScriptRoot/A/a.ps1`n. `$PSScriptRoot/B/b.ps1`n"
    Invoke-Q add -A; Invoke-Q commit -qm 'Merge main into PKT-02'
    $r = Invoke-Kit $checkScope @('-Packet', 'PKT-02', '-Base', $b0, '-Json')
    $cj = $r.Text | ConvertFrom-Json
    $mainSha = (& git rev-parse origin/main).Trim()
    Assert-That ($r.Code -eq 0 -and $cj.Base -eq $mainSha -and $cj.BriefBase -eq $b0 -and (@($cj.Changed) -join ',') -eq 'src/App.ps1,src/B/b.ps1') 'after merging the default branch, the files another packet landed are not this packet''s changes' $r.Text
    $touch = @($cj.Results | Where-Object { $_.Kind -eq 'TOUCH' })
    Assert-That ($touch.Count -eq 1 -and $touch[0].Detail -match '^1 changed lines') 'the touchpoint counts only this packet''s line' $r.Text
    # An edit to another packet's file inside the merge commit is still this packet's change.
    Write-MergeFile 'src/A/a.ps1' "function A { 'changed' }`n"
    Invoke-Q add -A; Invoke-Q commit -q --amend --no-edit
    $r = Invoke-Kit $checkScope @('-Packet', 'PKT-02', '-Base', $b0)
    Assert-That ($r.Code -eq 1 -and $r.Text -match 'OUTSIDE\s+src/A/a\.ps1' -and $r.Text -match 'default branch as last merged') 'an edit to a merged-in file in the merge commit is OUTSIDE' $r.Text
    # So is undoing it.
    Invoke-Q rm -q src/A/a.ps1; Invoke-Q commit -q --amend --no-edit
    $r = Invoke-Kit $checkScope @('-Packet', 'PKT-02', '-Base', $b0)
    Assert-That ($r.Code -eq 1 -and $r.Text -match 'OUTSIDE\s+src/A/a\.ps1') 'a revert of a merged-in file is OUTSIDE' $r.Text
    # Stacked on an unmerged dependency: the default branch is behind the brief's base, which stays.
    Invoke-Q switch -q -c pkt/pkt-03-gamma $pkt2Head
    Write-MergeFile 'src/C/c.ps1' "function C {}`n"
    Invoke-Q add -A; Invoke-Q commit -qm 'PKT-03'
    $r = Invoke-Kit $checkScope @('-Packet', 'PKT-03', '-Base', $pkt2Head, '-Json')
    $cj = $r.Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $cj.Base -eq $pkt2Head -and (@($cj.Changed) -join ',') -eq 'src/C/c.ps1') 'a stacked packet compares against its dependency''s head' $r.Text
    # Local origin/* refs don't pick the base: moving them can't make another branch's file look merged.
    Invoke-Q switch -q -c side $b0
    Write-MergeFile 'src/A/evil.ps1' "function Evil {}`n"
    Invoke-Q add -A; Invoke-Q commit -qm 'side'
    $side = (& git rev-parse HEAD).Trim()
    Invoke-Q switch -q -c pkt/pkt-02-forged $pkt2Head
    Invoke-Q merge -q --no-ff side -m 'Merge side'
    Invoke-Q update-ref refs/remotes/origin/main $side
    $r1 = Invoke-Kit $checkScope @('-Packet', 'PKT-02', '-Base', $b0)
    Invoke-Q symbolic-ref refs/remotes/origin/HEAD refs/heads/side
    $r2 = Invoke-Kit $checkScope @('-Packet', 'PKT-02', '-Base', $b0)
    Assert-That ($r1.Code -eq 1 -and $r1.Text -match 'OUTSIDE\s+src/A/evil\.ps1' -and $r2.Code -eq 1 -and $r2.Text -match 'OUTSIDE\s+src/A/evil\.ps1') 'a moved origin/main or origin/HEAD does not change the comparison base' ($r1.Text + "`n" + $r2.Text)
    Invoke-Q fetch -q origin; Invoke-Q remote set-head origin main
    # An amendment the owner merged on the default branch counts once the branch merges it.
    Invoke-Q switch -q main
    Write-MergeFile 'docs/plan/p/packets/PKT-02.md' (New-Packet 'PKT-02' 'Beta' 'W0' 'none' @('src/B/**', 'src/D/**') -Touch 'src/App.ps1')
    Invoke-Q add -A; Invoke-Q commit -qm 'Amend PKT-02: also owns src/D'; Invoke-Q push -q origin main
    Invoke-Q switch -q -c pkt/pkt-02-amended $pkt2Head
    & git merge -q origin/main -m 'Merge main' 2>&1 | Out-Null
    Write-MergeFile 'src/App.ps1' "# loader`n. `$PSScriptRoot/A/a.ps1`n. `$PSScriptRoot/B/b.ps1`n"
    Write-MergeFile 'src/D/d.ps1' "function D {}`n"
    Invoke-Q add -A; Invoke-Q commit -qm 'Merge main, then the amended work'
    $r = Invoke-Kit $checkScope @('-Packet', 'PKT-02', '-Base', $b0)
    Assert-That ($r.Code -eq 0 -and $r.Text -notmatch 'OUTSIDE') 'the packet is read at the comparison base, so a merged amendment counts' $r.Text
}
finally {
    Pop-Location
    if ($Keep) { Write-Host "kept $mergeRepo" } else { Remove-Item -Recurse -Force -LiteralPath $mergeRepo, $originRepo -ErrorAction SilentlyContinue }
}

Write-Host 'install'
$target = Join-Path ([System.IO.Path]::GetTempPath()) ("pw-install-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
New-Item -ItemType Directory -Path $target | Out-Null
try {
    & git -C $target init -q -b main
    & git -C $target remote add origin https://github.com/acme/widgets.git
    $installer = Join-Path $kit 'install.ps1'
    $r = Invoke-Kit $installer @('-Target', $target, '-WithInstructions')
    Assert-That ($r.Code -eq 0) 'install succeeds' $r.Text
    $cfgOut = Get-Content -Raw (Join-Path $target '.github/packet-workflow.json') | ConvertFrom-Json
    Assert-That ($cfgOut.repo -eq 'acme/widgets') 'install fills repo from the origin remote' $r.Text
    Assert-That ((Test-Path (Join-Path $target '.github/agents/packet-dispatcher.agent.md')) -and (Test-Path (Join-Path $target '.github/skills/packet-board/scripts/board.ps1'))) 'agents and skills land where Copilot looks' $r.Text
    Assert-That ((Get-Content -Raw (Join-Path $target '.github/copilot-instructions.md')) -match 'packet-workflow:start') 'instructions block added' $r.Text
    $edited = Join-Path $target '.github/skills/packet-plan/SKILL.md'
    Add-Content -LiteralPath $edited -Value 'local note'
    $r = Invoke-Kit $installer @('-Target', $target, '-WithInstructions')
    Assert-That ($r.Text -match 'kept\s+\.github/skills/packet-plan/SKILL\.md') 'upgrade keeps a locally edited file' $r.Text
    Assert-That ((Get-Content -Raw (Join-Path $target '.github/copilot-instructions.md')).Split('packet-workflow:start').Count -eq 2) 'instructions block is replaced, not duplicated' $r.Text
    $r = Invoke-Kit $installer @('-Target', $target, '-Force')
    Assert-That ($r.Text -match 'update\s+\.github/skills/packet-plan/SKILL\.md' -and -not ((Get-Content -Raw $edited) -match 'local note')) '-Force replaces it' $r.Text
    $sameAsSource = @(Get-ChildItem -LiteralPath (Join-Path $kit 'agents') -Filter '*.agent.md' | Where-Object { (Get-FileHash $_.FullName).Hash -ne (Get-FileHash (Join-Path $target ".github/agents/$($_.Name)")).Hash })
    Assert-That ($sameAsSource.Count -eq 0) 'with the default models, installed agents equal their sources (the model lines and the template agree)' (($sameAsSource | ForEach-Object Name) -join ', ')
    Assert-That ((Get-Content -Raw (Join-Path $target '.github/agents/packet-dispatcher.agent.md')) -match '(?m)^disable-model-invocation: true$') 'the dispatcher cannot be started as a subagent' ''
    $cfgPath = Join-Path $target '.github/packet-workflow.json'
    $cfgIn = Get-Content -Raw $cfgPath | ConvertFrom-Json -AsHashtable
    $cfgIn.models.light = @("Claude Sonnet 5.5 (Anthropic)", "it's fine")
    [System.IO.File]::WriteAllText($cfgPath, ($cfgIn | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    $r = Invoke-Kit $installer @('-Target', $target)
    $lightLine = (Get-Content (Join-Path $target '.github/agents/packet-reviewer-light.agent.md') | Where-Object { $_ -match '^model:' })
    Assert-That ($lightLine -eq "model: ['Claude Sonnet 5.5 (Anthropic)', 'it''s fine']" -and $r.Text -match 'update\s+\.github/agents/packet-reviewer-light\.agent\.md' -and $r.Text -notmatch 'update\s+\.github/agents/packet-reviewer-max') 'models in the config rewrite only that class''s agents, quoted' $r.Text
    Assert-That ($r.Text -match '\d+ file\(s\) already up to date' -and $r.Text -match 'Agent models: .*light Claude Sonnet 5\.5 \(Anthropic\)') 'the installer reports unchanged files and the models it wrote' $r.Text
    $implementer = Join-Path $target '.github/agents/packet-implementer.agent.md'
    [System.IO.File]::WriteAllText($implementer, ((Get-Content -Raw $implementer) -replace '(?m)^model:.*$', "model: ['Hand Picked']"), [System.Text.UTF8Encoding]::new($false))
    $cfgIn.models.standard = @('Claude Sonnet 5.5 (Anthropic)')
    [System.IO.File]::WriteAllText($cfgPath, ($cfgIn | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    $r = Invoke-Kit $installer @('-Target', $target)
    Assert-That ($r.Text -match 'kept\s+\.github/agents/packet-implementer\.agent\.md' -and $r.Text -match 'except the kept packet-implementer, which keeps its own model: line' -and (Get-Content -Raw $implementer) -match "model: \['Hand Picked'\]") 'a hand-edited agent is kept, and the models summary says so' $r.Text
}
finally { if (-not $Keep) { Remove-Item -Recurse -Force -LiteralPath $target } }

Write-Host ''
Write-Host "$($script:passes) passed, $($script:failures) failed"
if ($script:failures) { exit 1 }
