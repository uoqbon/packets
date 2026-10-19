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
    Assert-That ($r.Text -match 'ERROR\s+PKT-03\s+PKT-03 and PKT-05 can run at the same time and both own') 'existing file owned by two concurrent packets is an ERROR' $r.Text
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
    Assert-That ($r.Code -eq 1 -and $r.Text -match "ERROR\s+PKT-04\s+PKT-04 owns 'src/Web/\*\*' and PKT-07 owns 'src/Web/Admin/\*\*'") 'a glob inside a concurrent packet''s directory is an ERROR' $r.Text
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
}
finally {
    Pop-Location
    if ($Keep) { Write-Host "kept $repo" } else { Remove-Item -Recurse -Force -LiteralPath $repo }
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
}
finally { if (-not $Keep) { Remove-Item -Recurse -Force -LiteralPath $target } }

Write-Host ''
Write-Host "$($script:passes) passed, $($script:failures) failed"
if ($script:failures) { exit 1 }
