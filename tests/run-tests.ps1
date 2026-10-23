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
    # Three tiers: a Review tier of 4 (from the four-tier kit) warns but doesn't stop the phase; 5 is an error.
    Write-File 'docs/plan/phase-1/packets/PKT-09.md' (New-Packet 'PKT-09' 'Old tier' 'W2' 'PKT-03' @('src/OldTier/**') 'correctness' -Extra '- **Review tier:** 4')
    $r = Invoke-Kit $validate @('-Phase', 'phase-1')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'WARN\s+PKT-09\s+Review tier 4 is from before tiers 3 and 4 merged') 'a Review tier of 4 is a WARN, so an upgraded phase still validates and syncs' $r.Text
    Write-File 'docs/plan/phase-1/packets/PKT-09.md' (New-Packet 'PKT-09' 'Old tier' 'W2' 'PKT-03' @('src/OldTier/**') 'correctness' -Extra '- **Review tier:** 5')
    $r = Invoke-Kit $validate @('-Phase', 'phase-1')
    Assert-That ($r.Code -eq 1 -and $r.Text -match "ERROR\s+PKT-09\s+Review tier must be 1-3, 3 being the top tier \(got '5'\)") 'a Review tier of 5 is an ERROR' $r.Text
    Remove-Item -LiteralPath (Join-Path $repo 'docs/plan/phase-1/packets/PKT-09.md')
    # A human task's Parent names one packet of this repository that has a file; a packet takes none.
    $humanTask = { param($Id, $Parent) "# $Id · Sign off`n`n- **Human task:** $Id · **Priority:** P1`n- **Depends on:** none`n- **Parent:** $Parent`n`n## Goal`n`nSign it off.`n" }
    Write-File 'docs/plan/phase-1/packets/H-2.md' (& $humanTask 'H-2' 'PKT-99')
    Write-File 'docs/plan/phase-1/packets/H-3.md' (& $humanTask 'H-3' 'PKT-03, PKT-04')
    Write-File 'docs/plan/phase-1/packets/H-4.md' (& $humanTask 'H-4' 'H-1')
    Write-File 'docs/plan/phase-1/packets/PKT-09.md' (New-Packet 'PKT-09' 'Parented' 'W2' 'PKT-03' @('src/Parented/**') 'correctness' -Extra '- **Parent:** PKT-03')
    $r = Invoke-Kit $validate @('-Phase', 'phase-1')
    Assert-That ($r.Code -eq 1 -and $r.Text -match 'ERROR\s+H-2\s+Parent PKT-99 has no packet file' -and $r.Text -match "ERROR\s+H-3\s+Parent must name one packet ID" -and $r.Text -match 'ERROR\s+H-4\s+Parent must be a packet of this repository' -and $r.Text -match 'ERROR\s+PKT-09\s+only a human task names a Parent') 'a missing, doubled or human Parent, or a packet with one, is an ERROR' $r.Text
    Write-File 'docs/plan/phase-1/packets/H-2.md' (& $humanTask 'H-2' 'pkt-03')
    Write-File 'docs/plan/phase-1/packets/H-3.md' (& $humanTask 'H-3' 'none')
    Remove-Item -LiteralPath (Join-Path $repo 'docs/plan/phase-1/packets/H-4.md'), (Join-Path $repo 'docs/plan/phase-1/packets/PKT-09.md')
    $r = Invoke-Kit $validate @('-Phase', 'phase-1')
    Assert-That ($r.Code -eq 0 -and $r.Text -cnotmatch 'ERROR') 'a lower-case Parent naming a packet, or none, validates' $r.Text
    Remove-Item -LiteralPath (Join-Path $repo 'docs/plan/phase-1/packets/H-2.md'), (Join-Path $repo 'docs/plan/phase-1/packets/H-3.md')
    # Under -Phase, another phase's files aren't checked: one marked as a human task with a packet's ID is
    # still no Parent.
    Write-File 'docs/plan/phase-1/packets/H-2.md' (& $humanTask 'H-2' 'PKT-31')
    Write-File 'docs/plan/phase-9/packets/PKT-31.md' "# PKT-31 · Misfiled`n`n- **Human task:** PKT-31 · **Priority:** P1`n`n## Goal`n`nOops.`n"
    $r = Invoke-Kit $validate @('-Phase', 'phase-1')
    Assert-That ($r.Code -eq 1 -and $r.Text -match 'ERROR\s+H-2\s+Parent PKT-31 is a human task') 'a Parent that is another phase''s human task is an ERROR, even under -Phase' $r.Text
    Remove-Item -LiteralPath (Join-Path $repo 'docs/plan/phase-1/packets/H-2.md')
    Remove-Item -Recurse -LiteralPath (Join-Path $repo 'docs/plan/phase-9')
    & git add -A; & git commit -qm 'fix overlaps' | Out-Null

    Write-Host 'board: sync, show, next, deps'
    $r = Invoke-Kit $board @('sync', '-DryRun')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'sync: 6 created') 'dry-run sync would create six items' $r.Text
    $r = Invoke-Kit $board @('sync')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'sync: 6 created, 0 updated') 'sync creates six items' $r.Text
    Assert-That ($r.Text -match 'linked PKT-02 to 1 dependency') 'sync links dependencies' $r.Text
    $g = (Invoke-Kit $board @('get', 'H-1')).Text | ConvertFrom-Json
    Assert-That ($r.Text -match 'linked PKT-01 under epic #99' -and $r.Text -match 'linked H-1 under epic #99' -and $g.Parent -eq '99') 'sync puts packets and human tasks under the plan''s root item' $r.Text
    $r = Invoke-Kit $board @('sync')
    Assert-That ($r.Code -eq 0 -and $r.Text -match '0 created, 0 updated, 6 unchanged' -and $r.Text -notmatch 'linked') 'second sync is a no-op' $r.Text
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
    Assert-That ($r.Code -eq 0 -and $r.Text -match '^HOLD session-a \S+ \d+ \(kept, nothing posted; (29|30)m of 30m left, renews under 20m\)$') 'a check within the lease holds without posting, and says how much is left' $r.Text
    $r = Invoke-Kit $board @('claims', 'PKT-01')
    Assert-That (@($r.Text -split "`n" | Where-Object { $_ -match 'session-a' }).Count -eq 1 -and $r.Text -notmatch 'session-b') 'so the holder still has one claim comment; the lost claim is gone' $r.Text
    $r = Invoke-Kit $board @('claim', 'PKT-01', 'session-a', '-Force')
    Assert-That ($r.Code -eq 0 -and $r.Text -match '^HOLD session-a .*\(renewed; 30m left\)$') '-Force renews at once' $r.Text
    # Age session-a's claims on the board: 11 minutes is past a third of the lease, so the check renews.
    $ageClaims = {
        param([string]$Claim, [double]$Minutes)
        $file = Join-Path $repo '.git/packet-board.json'
        $lb = Get-Content -Raw -LiteralPath $file | ConvertFrom-Json -AsHashtable
        foreach ($list in $lb.comments.Values) { foreach ($c in @($list)) { if ($c.body -match "^``packet:claim $Claim``") { $c.createdAt = ([DateTimeOffset]$c.createdAt).AddMinutes(-$Minutes).ToString('o') } } }
        [System.IO.File]::WriteAllText($file, ($lb | ConvertTo-Json -Depth 64), [System.Text.UTF8Encoding]::new($false))
    }
    & $ageClaims 'session-a' 11
    $r = Invoke-Kit $board @('claim', 'PKT-01', 'session-a')
    $c = Invoke-Kit $board @('claims', 'PKT-01')
    Assert-That ($r.Code -eq 0 -and $r.Text -match '\(renewed; 30m left\)$' -and @($c.Text -split "`n" | Where-Object { $_ -match 'session-a' }).Count -eq 3) 'a claim a third of the way through its lease renews, keeping the older comments' "$($r.Text)`n$($c.Text)"
    # Past the lease, another session takes over, and the old holder's check is LOST.
    & $ageClaims 'session-a' 31
    $r = Invoke-Kit $board @('claim', 'PKT-01', 'session-b')
    Assert-That ($r.Code -eq 0 -and $r.Text -match '^HOLD session-b .*\(renewed; 30m left\)$') 'after the lease lapses another session holds' $r.Text
    $r = Invoke-Kit $board @('claim', 'PKT-01', 'session-a')
    Assert-That ($r.Code -eq 1 -and $r.Text -match '^LOST session-b') 'and the old holder''s check is LOST' $r.Text
    $r = Invoke-Kit $board @('release', 'PKT-01', 'session-a')
    Assert-That ($r.Text -match 'released 3 claim') 'release deletes all of the session''s claim comments' $r.Text
    $r = Invoke-Kit $board @('claims', 'PKT-01')
    Assert-That ($r.Text -match 'session-b' -and $r.Text -notmatch 'session-a') 'and only that session''s' $r.Text
    [void](Invoke-Kit $board @('release', 'PKT-01', 'session-b'))
    $r = Invoke-Kit $board @('claim', 'PKT-01', 'session-c')
    Assert-That ($r.Code -eq 0) 'after release another session can hold' $r.Text
    [void](Invoke-Kit $board @('release', 'PKT-01', 'session-c'))

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
    [System.IO.File]::WriteAllText($planPath, ((Get-Content -Raw $planPath) -replace '(?m)^- \*\*Epic:\*\* #99', "- **Epic:** #99`n- **Feature:** #12"), [System.Text.UTF8Encoding]::new($false))
    $r = Invoke-Kit $validate @('-Phase', 'phase-1')
    Assert-That ($r.Code -eq 1 -and $r.Text -match 'ERROR\s+phase-1\s+docs/plan/phase-1/plan\.md names more than one root item \(Epic #99, Feature #12\)') 'a plan with two root lines fails validation' $r.Text
    $r = Invoke-Kit $board @('sync')
    Assert-That ($r.Code -eq 1 -and $r.Text -match 'PROBLEM docs/plan/phase-1/plan\.md: more than one root item' -and $r.Text -match 'Nothing synced') 'and sync refuses it before writing anything' $r.Text
    & git checkout -q -- docs/plan/phase-1/plan.md

    Write-Host 'board: Parent lines and parents set on the board'
    $h1Path = Join-Path $repo 'docs/plan/phase-1/packets/H-1.md'
    $h1Text = Get-Content -Raw $h1Path
    $setH1Parent = { param($Parent) [System.IO.File]::WriteAllText($h1Path, ($h1Text -replace '(?m)^(- \*\*Depends on:\*\* PKT-04)$', "`$1`n- **Parent:** $Parent"), [System.Text.UTF8Encoding]::new($false)) }
    $boardFile = Join-Path $repo '.git/packet-board.json'
    $setBoardParents = {
        param([hashtable]$Parents)
        $lb = Get-Content -Raw -LiteralPath $boardFile | ConvertFrom-Json -AsHashtable
        foreach ($row in $lb.items) { if ($Parents.ContainsKey($row.id)) { $row.parent = $Parents[$row.id] } }
        [System.IO.File]::WriteAllText($boardFile, ($lb | ConvertTo-Json -Depth 64), [System.Text.UTF8Encoding]::new($false))
    }
    $pkt03 = (Invoke-Kit $board @('get', 'PKT-03')).Text | ConvertFrom-Json
    $h1 = (Invoke-Kit $board @('get', 'H-1')).Text | ConvertFrom-Json
    # H-1 sits under the epic from the first sync; its new Parent line names PKT-03. Without -Force it stays.
    & $setH1Parent 'pkt-03'
    $r = Invoke-Kit $board @('sync')
    $g = (Invoke-Kit $board @('get', 'H-1')).Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $r.Text -match "note: H-1 #$($h1.Number) is under #99, and its place is under PKT-03 #$($pkt03.Number): sync -Phase phase-1 -Force moves it" -and $g.Parent -eq '99') 'a Parent line names a human task''s new place; without -Force an item under another parent stays there' $r.Text
    $r = Invoke-Kit $board @('sync', '-DryRun', '-Force')
    $g = (Invoke-Kit $board @('get', 'H-1')).Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $r.Text -match "would move H-1 #$($h1.Number) under PKT-03 #$($pkt03.Number) \(now under #99\)" -and $g.Parent -eq '99') 'sync -DryRun -Force shows the move and makes none' $r.Text
    $r = Invoke-Kit $board @('sync', '-Force')
    $g = (Invoke-Kit $board @('get', 'H-1')).Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $r.Text -match "moved H-1 under PKT-03 #$($pkt03.Number) \(was under #99\)" -and [string]$g.Parent -eq [string]$pkt03.Number) 'sync -Force moves it under its Parent packet' $r.Text
    $r = Invoke-Kit $board @('sync')
    Assert-That ($r.Code -eq 0 -and $r.Text -notmatch '(linked|moved|note:) H-1') 'and the next sync leaves it there' $r.Text
    & $setBoardParents @{ 'H-1' = $null; 'PKT-02' = '77' }
    $r = Invoke-Kit $board @('sync')
    $g = (Invoke-Kit $board @('get', 'H-1')).Text | ConvertFrom-Json
    $p2 = (Invoke-Kit $board @('get', 'PKT-02')).Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $r.Text -match "linked H-1 under PKT-03 #$($pkt03.Number)" -and $r.Text -match 'note: PKT-02 #\d+ is under #77, and its place is under epic #99' -and [string]$g.Parent -eq [string]$pkt03.Number -and $p2.Parent -eq '77') 'a human task with no parent is linked under its Parent packet; a parent set on the board is named and kept' $r.Text
    & $setBoardParents @{ 'PKT-02' = '99' }
    & $setH1Parent 'PKT-09'
    $missing = "note: H-1 #$($h1.Number) was left where it is: its Parent PKT-09 isn't on the board"
    $dry = Invoke-Kit $board @('sync', '-DryRun', '-Force')
    $r = Invoke-Kit $board @('sync')
    Assert-That ($r.Code -eq 0 -and $r.Text -match $missing -and $dry.Text -match $missing -and $dry.Text -notmatch 'PKT-09 \(new\)') 'a Parent packet with no item that sync won''t create is named, the same in a dry run, and the task left where it is' "$($dry.Text)`n$($r.Text)"
    Write-File 'docs/plan/phase-1/packets/H-5.md' (& $humanTask 'H-5' 'PKT-09')
    $r = Invoke-Kit $board @('sync', '-DryRun')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'would create H-5' -and $r.Text -match "note: H-5 \(new\) would get no parent: its Parent PKT-09 isn't on the board") 'and a new task with such a Parent is told it would get no parent' $r.Text
    Remove-Item -LiteralPath (Join-Path $repo 'docs/plan/phase-1/packets/H-5.md')
    # A Parent packet this sync would create is (new) in its dry run: H-1 with no parent would go under it,
    # and H-1 under the epic is named. Nothing is created.
    Write-File 'docs/plan/phase-1/packets/PKT-08.md' (New-Packet 'PKT-08' 'Sign-off home' 'W2' 'PKT-03' @('src/SignOff/**') 'correctness')
    & $setH1Parent 'PKT-08'
    & $setBoardParents @{ 'H-1' = $null }
    $r = Invoke-Kit $board @('sync', '-DryRun')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'would create PKT-08' -and $r.Text -match "would put H-1 #$($h1.Number) under PKT-08 \(new\)") 'in a dry run, a task with no parent would go under a Parent packet this sync creates' $r.Text
    & $setBoardParents @{ 'H-1' = '99' }
    $r = Invoke-Kit $board @('sync', '-DryRun')
    Assert-That ($r.Code -eq 0 -and $r.Text -match "note: H-1 #$($h1.Number) is under #99, and its place is under PKT-08 \(new\)") 'and a task under the root is named against it' $r.Text
    Remove-Item -LiteralPath (Join-Path $repo 'docs/plan/phase-1/packets/PKT-08.md')
    & $setBoardParents @{ 'H-1' = [string]$pkt03.Number }
    & $setH1Parent 'PKT-03'
    & git add -A; & git commit -qm 'H-1 under PKT-03' | Out-Null

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
    $r = Invoke-Kit $reviewScope @('-Base', 'HEAD~1', '-PreviousTier', '1', '-FixedConfirmed', '-Json')
    $s = $r.Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $s.Tier -eq 2 -and $s.Agent -eq 'packet-reviewer-standard') 'a round whose confirmed findings were fixed goes up a tier' $r.Text
    $r = Invoke-Kit $reviewScope @('-Base', 'HEAD~1', '-PreviousTier', '4', '-Json')
    $s = $r.Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $s.Tier -eq 3 -and $s.Name -eq 'deep' -and $s.Agent -eq 'packet-reviewer-deep') 'a previous round at tier 4 (before tiers 3 and 4 merged) carries as tier 3, the top' $r.Text
    Write-File 'docs/plan/phase-1/packets/PKT-10.md' (New-Packet 'PKT-10' 'Old tier' 'W3' 'PKT-03' @('docs/old-tier/**') 'correctness' -Extra '- **Review tier:** 4')
    & git add -A; & git commit -qm 'packet with an old tier' | Out-Null
    Write-File 'docs/old-tier/notes.md' "a note`n"
    & git add -A; & git commit -qm 'old-tier note' | Out-Null
    $r = Invoke-Kit $reviewScope @('-Base', 'HEAD~1', '-Packet', 'PKT-10', '-Json')
    $s = $r.Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $s.Tier -eq 3 -and $s.Floor -eq 1 -and $s.Agent -eq 'packet-reviewer-deep' -and ($s.Reasons -join ' ') -match "raised to 3 by PKT-10's Review tier line") 'a packet''s Review tier of 4 raises a docs diff to 3, the top, never to a tier with no agent' $r.Text
    & git reset -q --hard HEAD~2
    $agentsCfg = Join-Path ([System.IO.Path]::GetTempPath()) "pw-cfg-$([guid]::NewGuid().ToString('n')).json"
    $old4 = $cfg.Clone(); $old4.review = $cfg.review.Clone(); $old4.review.agents = @{ '3' = 'packet-reviewer-deep'; '4' = 'packet-reviewer-max' }
    Set-Content -LiteralPath $agentsCfg -Value ($old4 | ConvertTo-Json -Depth 10)
    $r = Invoke-Kit $reviewScope @('-Base', 'main', '-Json', '-ConfigPath', $agentsCfg)
    $s = $r.Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $s.Tier -eq 3 -and $s.Agent -eq 'packet-reviewer-deep') 'the old template''s "4": "packet-reviewer-max" is ignored: tier 3 runs the deep reviewer' $r.Text
    $old4.review.agents = @{ '3' = 'my-deep'; '4' = 'my-max' }
    Set-Content -LiteralPath $agentsCfg -Value ($old4 | ConvertTo-Json -Depth 10)
    $r = Invoke-Kit $reviewScope @('-Base', 'main', '-Json', '-ConfigPath', $agentsCfg)
    $s = $r.Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $s.Tier -eq 3 -and $s.Agent -eq 'my-max' -and ($s.Reasons -join ' ') -match 'review\.agents\.4 \(my-max\) runs tier 3') 'a project''s own tier-4 reviewer runs tier 3, never its weaker tier-3 one' $r.Text
    $r = Invoke-Kit $reviewScope @('-Base', 'HEAD~1', '-Json', '-ConfigPath', $agentsCfg)
    $s = $r.Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $s.Tier -eq 1 -and $s.Agent -eq 'packet-reviewer-light') 'a project''s tier-4 reviewer changes nothing below tier 3' $r.Text
    Remove-Item -LiteralPath $agentsCfg
    $r = Invoke-Kit $reviewScope @('-Base', 'main', '-Packet', 'PKT-03', '-Since', $apiSha, '-Confirmed', 'security,concurrency', '-PreviousTier', '3', '-FixedConfirmed', '-Json')
    $s = $r.Text | ConvertFrom-Json
    Assert-That ($r.Code -eq 0 -and $s.Tier -eq 3 -and $s.Agent -eq 'packet-reviewer-deep' -and ($s.Lenses -contains 'security') -and ($s.Lenses -contains 'concurrency') -and -not ($s.Lenses | Where-Object { $_ -match ',' })) 'round 2: comma-separated -Confirmed splits, and a fixed round at tier 3 stays at the top' $r.Text
    $r = Invoke-Kit $reviewScope @('-Base', 'main', '-Packet', 'PKT-03', '-Since', $apiSha, '-Confirmed', '-', '-PreviousTier', '3', '-Json')
    $s = $r.Text | ConvertFrom-Json
    Assert-That (-not ($s.Lenses -contains '-') -and $s.Lenses.Count -ge 1) 'round 2 after a pass: "-" is not a lens, and a round never has none' $r.Text
    Write-File 'src/Core/Clock.cs' "class Clock {}`n"
    $cfgText = Get-Content -Raw (Join-Path $repo '.github/packet-workflow.json')
    Write-File '.github/packet-workflow.json' ($cfgText -replace '"deepPaths": "\^src/Core/"', '"deepPaths": ""')
    & git add -A; & git commit -qm 'core, and a config edit that drops the deep path' | Out-Null
    $r = Invoke-Kit $reviewScope @('-Base', 'HEAD~1', '-Json')
    $s = $r.Text | ConvertFrom-Json
    Assert-That ($s.Tier -eq 3 -and ($s.Reasons -join ' ') -match 'project deep path' -and ($s.Reasons -join ' ') -match 'review machinery') 'the base config decides: a branch dropping deepPaths still gets the raise (and the config edit is machinery)' $r.Text
    Write-File '.github/packet-workflow.json' $cfgText
    & git add -A; & git commit -qm 'restore config' | Out-Null
    # review-tier.sh parity: async code is concurrency (tier 3); a NUL byte can't hide a file's lines;
    # a project lens is review machinery (tier 3, the top).
    Write-File 'src/Api/Svc.cs' "class Svc {`n  async Task Run() { await Task.Delay(10); }`n}`n"
    & git add -A; & git commit -qm 'async' | Out-Null
    $r = Invoke-Kit $reviewScope @('-Base', 'HEAD~1', '-Json'); $s = $r.Text | ConvertFrom-Json
    Assert-That ($s.Tier -eq 3 -and ($s.Reasons -join ' ') -match 'concurrency in added lines') 'async/await raises the tier to 3, as review-tier.sh does' $r.Text
    $js = "// `0`n" + ((1..1200 | ForEach-Object { "if (x) { save(); }" }) -join "`n") + "`n"
    [System.IO.File]::WriteAllText((Join-Path $repo 'src/Api/app.js'), $js)
    & git add -A; & git commit -qm 'nul' | Out-Null
    $r = Invoke-Kit $reviewScope @('-Base', 'HEAD~1', '-Json'); $s = $r.Text | ConvertFrom-Json
    Assert-That ($s.Tier -eq 3 -and $s.Lines -ge 1200 -and ($s.Reasons -join ' ') -match 'lines > 300') 'a NUL byte does not hide 1200 lines (read with NULs dropped)' $r.Text
    Write-File '.github/packet-lenses/data.md' "# Lens: data`n`nblocking: nothing`n"
    & git add -A; & git commit -qm 'lens' | Out-Null
    $r = Invoke-Kit $reviewScope @('-Base', 'HEAD~1', '-Json'); $s = $r.Text | ConvertFrom-Json
    Assert-That ($s.Tier -eq 3 -and $s.Agent -eq 'packet-reviewer-deep' -and ($s.Reasons -join ' ') -match 'review machinery') 'a project lens edit is review machinery (tier 3)' $r.Text
    $cfgText = Get-Content -Raw (Join-Path $repo '.github/packet-workflow.json')
    Write-File '.github/packet-workflow.json' ($cfgText -replace '"lenses": "\.github/packet-lenses"', '"lenses": "./review/lenses"')
    & git add -A; & git commit -qm 'move lenses' | Out-Null
    Write-File 'review/lenses/correctness.md' "# Lens: correctness`n`nblocking: nothing`n"
    & git add -A; & git commit -qm 'lens in configured dir' | Out-Null
    $r = Invoke-Kit $reviewScope @('-Base', 'HEAD~1', '-Json'); $s = $r.Text | ConvertFrom-Json
    Assert-That ($s.Tier -eq 3 -and ($s.Reasons -join ' ') -match 'review machinery path: review/lenses/') 'a lens edit under a configured paths.lenses is review machinery too' $r.Text
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
    $headings = [ordered]@{
        a = "# TextKit (e2e): plan`n`n- **Epic:** #0`n"; b = "# Disaster recovery plan`n`n- **Epic:** #12`n"; c = "# Office floor-plan`n"; d = "# Migration-Plan`n"; e = "# Checkout — Plan`n"
        f = "# F`n`n- **Feature:** AB#12`n"; g = "# G`n`n- **Story:** AB#7`n- **User Story:** AB#0`n"; h = "# H`n`n- **Epic:** AB#1`n- **User Story:** AB#2`n"
    }
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
"roots=" + ((@('b', 'f', 'g', 'h') | ForEach-Object { `$i = Get-PwPhaseInfo -Config `$cfg -Phase `$_; "`$(if (`$i.Root) { "`$(`$i.Root.Level):`$(`$i.Root.Ref)" } else { 'none' })/`$(@(`$i.Roots).Count)" }) -join '|')
. '$((Join-Path $skills 'packet-board/scripts/providers/github-common.ps1').Replace("'", "''"))'
function Confirm-PwGhLabel { param(`$Config, `$Name, `$Color, `$Description, [switch]`$DryRun) `$true }
"labels=" + ((Initialize-PwGhLabels -Config @{ labels = @{ packet = 'packet'; human = 'human-task'; needsHuman = 'needs-human'; followUp = 'follow-up' } } -Keys 'needsHuman', 'followUp') -join ',')
"claim=`$(New-PwClaimId)"
"host=`$(([System.Net.Dns]::GetHostName() -split '\.')[0])"
# Credit estimates: stage 5's PKT-1 (S, three rounds of 4, 3 and 1 lenses, two fix rounds), its markers
# written as tier=4 before tiers 3 and 4 merged: priced at tier 3.
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
`$bad = Merge-PwHashtable `$script:Defaults @{ budget = @{ creditsPerRun = @{ reviewerByTier = @{ M = @(30, 70) } } } }
try { [void](Get-PwCreditEstimate -Config `$bad -Size 'M' -Rounds `$p2); 'budget-check=none' } catch { "budget-check=`$(`$_.Exception.Message)" }
# An install from before tiers 3 and 4 merged lists four numbers: the third is dropped, the fourth prices tier 3.
`$four = Merge-PwHashtable `$script:Defaults @{ budget = @{ creditsPerRun = @{ reviewerByTier = @{ M = @(30, 70, 160, 280) } } } }
"four-tier=`$((Get-PwCreditEstimate -Config `$four -Size 'M' -Rounds `$p2).Credits)"
# A quoted number in a four-entry list must not leave three numbers that pass as a three-tier list.
`$quoted = Merge-PwHashtable `$script:Defaults @{ budget = @{ creditsPerRun = @{ reviewerByTier = @{ M = @(30, '70', 160, 280) } } } }
try { [void](Get-PwCreditEstimate -Config `$quoted -Size 'M' -Rounds `$p2); 'quoted-check=none' } catch { "quoted-check=`$(`$_.Exception.Message)" }
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
    Assert-That ($r.Text -match 'roots=epic:#12/1\|feature:AB#12/1\|story:AB#7/1\|none/2(\r?\n|$)') 'a plan''s root line is an Epic, a Feature or a (User) Story; a placeholder is none; two lines are no root' $r.Text
    Assert-That ($r.Text -match 'labels=needs-human,follow-up') 'the follow-up labels can be set up on their own (Azure Boards setup)' $r.Text
    $claimId = if ($r.Text -match 'claim=(\S+)') { $Matches[1] } else { '' }
    $hostName = if ($r.Text -match 'host=(\S+)') { $Matches[1] } else { '' }
    Assert-That ($claimId -match '^session-[0-9a-f]{8}-\d{8}T\d{6}Z-\d{5}$' -and (-not $hostName -or $claimId -notmatch [regex]::Escape($hostName))) 'a claim id carries a hash of the machine, not its host name' $r.Text
    # Base 50 + 105. Rounds: 300 + 4×35 + 4×195 + 40 = 1260; 300 + 3×35 + 0.85×3×195 + 40 = 942; 300 + 35 + 0.85×195 = 501.
    Assert-That ($r.Text -match 'estimate=2858\|runs=8\|impl=3\|rounds=3') 'credit estimate for stage 5: settle rows ignored, a row without Runs is one run per lens' $r.Text
    Assert-That ($r.Text -match 'grouped=1071\|runs=2') 'two runs of two lenses count 2.8 runs' $r.Text
    # PKT-02 (M): 250 base and 330 + 2×35 + 2×280 + 55 = 1015 in September (its round 1), 330 + 35 + 0.85×280 + 55 = 658 in October; only PKT-01 has finished.
    Assert-That ($r.Text -match 'summary=4781\|avg=2858\|month=2026-10:3516\|left=8984\|more=3\|finished=True,False\|counted=2') 'credit summary: month by round date, average over finished packets, packets with no round left out' $r.Text
    Assert-That ($r.Text -match 'budget-check=config: budget\.creditsPerRun\.reviewerByTier\.M must list three numbers') 'a malformed credits table stops the estimate with a clear message' $r.Text
    Assert-That ($r.Text -match 'four-tier=1923(\r?\n|$)') 'a four-number reviewerByTier from before the merge prices tier 3 at its fourth number' $r.Text
    Assert-That ($r.Text -match 'quoted-check=config: budget\.creditsPerRun\.reviewerByTier\.M must list three numbers') 'a four-entry list with a quoted number stops the estimate, not misread as three tiers' $r.Text
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
    $issue = { param($n, $title, $state, $reason, $label) @{ number = $n; title = $title; state = $state; state_reason = $reason; labels = @(@{ name = $label }); html_url = "https://example.test/issues/$n"; updated_at = '2026-10-01T00:00:00Z' } }
    $ghData = @{
        # Other repositories' packet issues (remotes), listed by label as the REST API does.
        issues = @{
            'example/api' = @((& $issue 3 'API-3 · Orders endpoint' 'closed' 'completed' 'packet'),
                (& $issue 4 'API-4 · Refunds' 'open' $null 'packet'),
                (& $issue 5 'API-5 · Dropped' 'closed' 'not_planned' 'packet'),
                (& $issue 6 'API-6 · Retried' 'closed' 'completed' 'packet'),
                (& $issue 16 'API-6 · Retried' 'open' $null 'packet'),
                (& $issue 10 'API-10 · Closed long ago' 'closed' $null 'packet'),
                (& $issue 11 'API-11 · Same as API-3' 'closed' 'duplicate' 'packet'),
                ((& $issue 8 'API-8 · A pull request' 'closed' 'completed' 'packet') + @{ pull_request = @{ url = 'p8' } }))
            'example/web' = @((& $issue 2 'WEB-2 · Pages' 'closed' 'completed' 'pkt'), (& $issue 7 'WEB-7 · Other label' 'closed' 'completed' 'packet'))
        }
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
# On Windows pwsh resolves gh to this file ahead of gh.cmd and runs it in the caller's process, under the
# kit's strict mode; run as the separate process it is elsewhere.
Set-StrictMode -Off; $ErrorActionPreference = 'Continue'
$data = Get-Content -Raw (Join-Path $PSScriptRoot 'gh-data.json') | ConvertFrom-Json -AsHashtable
$a = @($args)
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'calls.log') -Value ($a -join ' ')
if ($a[0] -eq 'pr' -and $a[1] -eq 'list') { ConvertTo-Json -InputObject @($data.prs) -Depth 5; exit 0 }
$issuesPath = @($a | Where-Object { "$_" -match '^repos/[^/]+/[^/]+/issues\?' })[0]
if ($a[0] -eq 'api' -and $issuesPath -match '^repos/(?<repo>[^/]+/[^/]+)/issues\?.*\blabels=(?<label>[^&]+)') {
    $repo = $Matches.repo; $label = [uri]::UnescapeDataString($Matches.label)
    if (-not $data.issues.ContainsKey($repo)) { [Console]::Error.WriteLine("HTTP 404: Not Found (repos/$repo)"); exit 1 }
    ConvertTo-Json -InputObject @(, @($data.issues[$repo] | Where-Object { @($_.labels | ForEach-Object { $_.name }) -contains $label })) -Depth 6; exit 0
}
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
        Assert-That ($r.Code -eq 0 -and $line -eq 'PKT-01:11:2183:True,PKT-02:12:768:False' -and $c.Total -eq 2951 -and $c.PerFinishedPacket -eq 2183 -and $c.Month -eq '2026-10' -and $c.ThisMonth -eq 1371) 'progress -Credits: newest PR per packet, untrusted rounds dropped, credits per packet, phase and month' $r.Text
        $r = Invoke-Kit $progress @('-WorkingTree', '-Credits', '-Today', '2026-09-30', '-Json')
        $c = ($r.Text | ConvertFrom-Json).Credits
        Assert-That ($r.Code -eq 0 -and $c.Month -eq '2026-09' -and $c.ThisMonth -eq 1580) 'a round reported at 23:30 UTC on 30 September counts in September, with its packet''s base' $r.Text
        $r = Invoke-Kit $progress @('-WorkingTree', '-Credits')
        Assert-That ($r.Code -eq 0 -and $r.Text -match 'PKT-02\s+M\s+PR #12\s+1 round\(s\), 1 reviewer run\(s\), 2 implementer run\(s\)\s+768\s+\(in review\)' -and $r.Text -match "phase 2,951 · 2,183 per finished packet · $([DateTime]::UtcNow.ToString('yyyy-MM')):") 'progress -Credits text: the estimate per packet and the UTC month by default' $r.Text

        Write-Host 'remotes: dependencies on other repositories'
        $callLog = Join-Path $fakeBin 'calls.log'
        $remoteCalls = { @(Get-Content -LiteralPath $callLog -ErrorAction SilentlyContinue | Where-Object { $_ -match '/issues\?' }) }
        $plainCfg = Get-Content -Raw (Join-Path $repo '.github/packet-workflow.json')
        $rcfg = $plainCfg | ConvertFrom-Json -AsHashtable
        $rcfg.remotes = @{ API = @{ repo = 'example/api' }; WEB = @{ repo = 'example/web'; label = 'pkt' } }
        Write-File '.github/packet-workflow.json' ($rcfg | ConvertTo-Json -Depth 10)
        Write-File 'docs/plan/phase-1/packets/PKT-11.md' (New-Packet 'PKT-11' 'Orders page' 'W1' 'PKT-01, API-3, WEB-2' @('src/Orders/**') 'correctness')
        Write-File 'docs/plan/phase-1/packets/PKT-12.md' (New-Packet 'PKT-12' 'Refunds page' 'W1' 'API-4, API-5, API-6, API-8, API-9, API-10, API-11, WEB-7' @('src/Refunds/**') 'correctness')
        $altCfg = Join-Path ([System.IO.Path]::GetTempPath()) "pw-cfg-$([guid]::NewGuid().ToString('n')).json"
        Set-Content -LiteralPath $altCfg -Value $plainCfg
        $r = Invoke-Kit $validate @('-Phase', 'phase-1', '-ConfigPath', $altCfg)
        Assert-That ($r.Code -eq 1 -and $r.Text -match "ERROR\s+PKT-11\s+depends on API-3, which has no packet file \(a packet in another repository needs its prefix API in the config's remotes\)") 'without remotes, a dependency on another repository''s packet is an ERROR that names the fix' $r.Text
        $r = Invoke-Kit $validate @('-Phase', 'phase-1', '-Json')
        $v = $r.Text | ConvertFrom-Json
        Assert-That ($r.Code -eq 0 -and $v.Summary.Errors -eq 0 -and (@($v.Summary.Remote | ForEach-Object { "$($_.Id)@$($_.Repo)" }) -join ',') -eq 'API-3@example/api,API-4@example/api,API-5@example/api,API-6@example/api,API-8@example/api,API-9@example/api,API-10@example/api,API-11@example/api,WEB-2@example/web,WEB-7@example/web' -and @($remoteCalls.Invoke()).Count -eq 0) 'with remotes, those dependencies validate, offline, and the summary lists them' $r.Text
        $r = Invoke-Kit $validate @('-Phase', 'phase-1')
        Assert-That ($r.Text -match 'in other repositories: API-3 in example/api \(for PKT-11\), API-4 in example/api \(for PKT-12\),.* WEB-2 in example/web \(for PKT-11\)') 'the text summary names each one, its repository and who waits on it' $r.Text
        foreach ($case in @(
                @{ Remotes = @{ PKT = @{ repo = 'example/api' } }; Error = "remotes.PKT is this repository's own prefix"; Name = 'this repository''s own prefix' },
                @{ Remotes = @{ api = @{ repo = 'example/api' } }; Error = "remotes key 'api' must be a packet ID prefix"; Name = 'a lower-case prefix' },
                @{ Remotes = @{ API = @{ repo = 'example api' } }; Error = 'remotes.API.repo must be the other GitHub repository as owner/name'; Name = 'a malformed repository' },
                @{ Remotes = @{ API = 'example/api' }; Error = 'remotes.API.repo must be the other GitHub repository as owner/name'; Name = 'a bare string' },
                @{ Remotes = @{ API = @{ repo = 'Example/Sample' } }; Error = 'remotes.API names this repository (example/sample)'; Name = 'this repository itself' },
                @{ Remotes = @{ API = @{ repo = 'example/api'; label = ' ' } }; Error = "remotes.API.label must be that repository's packet label"; Name = 'a blank label' })) {
            $bad = $plainCfg | ConvertFrom-Json -AsHashtable
            $bad.remotes = $case.Remotes
            Set-Content -LiteralPath $altCfg -Value ($bad | ConvertTo-Json -Depth 10)
            $r = Invoke-Kit $validate @('-Phase', 'phase-1', '-ConfigPath', $altCfg)
            Assert-That ($r.Code -eq 2 -and $r.Text -match [regex]::Escape($case.Error)) "remotes refuses $($case.Name)" $r.Text
        }
        # JSON keeps both keys; the config merge folds case, so the check must see them as written.
        Set-Content -LiteralPath $altCfg -Value ($plainCfg -replace '"remotes": \{\}', '"remotes": { "API": { "repo": "example/api" }, "api": { "repo": "evil/other" } }')
        $r = Invoke-Kit $validate @('-Phase', 'phase-1', '-ConfigPath', $altCfg)
        Assert-That ($plainCfg -match '"remotes": \{\}' -and $r.Code -eq 2 -and $r.Text -match "remotes key 'api' must be a packet ID prefix") 'remotes refuses a lower-case key beside its upper-case twin, which would replace it' $r.Text
        foreach ($block in '"remotes": { "API": { "repo": "example/api" } }, "Remotes": { "api": { "repo": "evil/api" } }', '"REMOTES": { "api": { "repo": "evil/api" } }') {
            Set-Content -LiteralPath $altCfg -Value ($plainCfg -replace '"remotes": \{\}', $block)
            $r = Invoke-Kit $validate @('-Phase', 'phase-1', '-ConfigPath', $altCfg)
            Assert-That ($r.Code -eq 2 -and $r.Text -match 'write remotes once, in lower case') "remotes refuses a block spelled otherwise: $($block.Substring(0, 30))…" $r.Text
        }
        [void](Invoke-Kit $board @('sync'))
        # An item on this board that carries another repository's ID (here closed and Done) must never stand in for it.
        $boardFile = Join-Path $repo '.git/packet-board.json'
        $lb = Get-Content -Raw -LiteralPath $boardFile | ConvertFrom-Json -AsHashtable
        $lb.items = @($lb.items) + @(, @{
                number = [int]$lb.nextNumber; id = 'API-4'; title = 'API-4 · Made here'; body = ''; kind = 'packet'; labels = @('packet')
                status = 'Done'; priority = 'P0'; size = 'S'; wave = 'W0'; target = $null; closed = $true; closedReason = 'completed'
                milestone = 'Phase 1 · Sample'; assignees = @(); dependencies = @(); parent = $null; updatedAt = '2026-10-01T00:00:00Z'
            })
        $lb.nextNumber = [int]$lb.nextNumber + 1
        [System.IO.File]::WriteAllText($boardFile, ($lb | ConvertTo-Json -Depth 64), [System.Text.UTF8Encoding]::new($false))
        $r = Invoke-Kit $board @('sync')
        $g = (Invoke-Kit $board @('get', 'PKT-12')).Text | ConvertFrom-Json
        Assert-That ($r.Code -eq 0 -and $r.Text -match 'orphan API-4' -and $g.Body -match '\*\*Depends on:\*\* API-4, API-5' -and @($g.Dependencies).Count -eq 0) 'sync neither annotates nor links a remote dependency to the item here with its ID' $r.Text
        Remove-Item -LiteralPath $callLog -ErrorAction SilentlyContinue
        $r = Invoke-Kit $board @('show', '-WorkingTree')
        Assert-That ($r.Code -eq 0 -and @($remoteCalls.Invoke()).Count -eq 0) 'board show reads no other repository' $r.Text
        $r = Invoke-Kit $board @('next', '-WorkingTree', '-Json')
        $n = @($r.Text | ConvertFrom-Json)
        $p11 = @($n | Where-Object { $_.Id -eq 'PKT-11' })[0]; $p12 = @($n | Where-Object { $_.Id -eq 'PKT-12' })[0]
        Assert-That ($r.Code -eq 0 -and $p11.Verdict -eq 'START') 'dependencies closed as completed in other repositories (one under its own label) let a packet start' $r.Text
        $why = @($p12.Reasons) -join ' | '
        Assert-That ($p12.Verdict -eq 'BLOCKED' -and $why -match 'API-4 is open in example/api#4' -and $why -match 'API-5 was closed as not planned in example/api#5' -and $why -match 'API-6 is open in example/api#16' -and $why -match 'API-8 has no issue in example/api with the label packet' -and $why -match 'API-9 has no issue in example/api' -and $why -match 'API-10 was closed as not completed in example/api#10' -and $why -match 'API-11 was closed as duplicate in example/api#11' -and $why -match 'WEB-7 has no issue in example/web with the label pkt') 'open (despite a Done item here with its ID), not planned, no reason, duplicate, a duplicate still open, a pull request and another label all block, each with its reason' $r.Text
        $calls = & $remoteCalls
        Assert-That ($calls.Count -eq 2 -and ($calls -join "`n") -match 'repos/example/api/issues\?state=all&labels=packet&' -and ($calls -join "`n") -match 'repos/example/web/issues\?state=all&labels=pkt&') 'each other repository is listed once per call, under its own packet label' ($calls -join "`n")
        $r = Invoke-Kit $board @('deps', 'PKT-11', '-WorkingTree')
        Assert-That ($r.Code -eq 0 -and $r.Text -match 'START PKT-11' -and $r.Text -match 'API-3\s+Done example/api#3' -and $r.Text -match 'WEB-2\s+Done example/web#2') 'deps shows other repositories'' dependencies with their issues' $r.Text
        $r = Invoke-Kit $board @('deps', 'PKT-12', '-WorkingTree')
        Assert-That ($r.Code -eq 1 -and $r.Text -match 'API-4\s+Open example/api#4' -and $r.Text -match 'API-9\s+Not found example/api(\r?\n|$)') 'deps exits 1 while one of them is open or missing' $r.Text
        $r = Invoke-Kit $progress @('-WorkingTree', '-Json')
        $pj = $r.Text | ConvertFrom-Json
        Assert-That ($r.Code -eq 0 -and @($pj.Startable | Where-Object { $_.Id -eq 'PKT-11' }).Count -eq 1 -and ((@($pj.Blocked | Where-Object { $_.Id -eq 'PKT-12' })[0].Reasons) -join ' | ') -match 'API-4 is open in example/api#4.*API-10 was closed as not completed') 'progress gives the same verdicts, from the other repository' $r.Text
        # A packet closed as completed whose status still says Ready is listed, and judged, all the same.
        [void](Invoke-Kit $board @('set', 'PKT-12', 'Closed=true'))
        $r = Invoke-Kit $progress @('-WorkingTree', '-Json')
        $pj = $r.Text | ConvertFrom-Json
        Assert-That ($r.Code -eq 0 -and ((@($pj.Blocked | Where-Object { $_.Id -eq 'PKT-12' })[0].Reasons) -join ' | ') -match 'API-4 is open in example/api#4') 'progress reads a closed but Ready packet''s remote dependencies too, never the item here with that ID' $r.Text
        $rcfg.remotes.API.repo = 'example/gone'
        Set-Content -LiteralPath $altCfg -Value ($rcfg | ConvertTo-Json -Depth 10)
        $r = Invoke-Kit $board @('deps', 'PKT-11', '-WorkingTree', '-ConfigPath', $altCfg)
        Assert-That ($r.Code -eq 2 -and $r.Text -match 'example/gone') 'a failed lookup in another repository is an error (exit 2), never a START' $r.Text
        Remove-Item -LiteralPath $altCfg
        Write-File '.github/packet-workflow.json' $plainCfg
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
    # With origin out of reach, it keeps the brief's base (a false alarm at worst), never the local refs.
    Invoke-Q symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    Invoke-Q remote set-url origin (Join-Path $mergeRepo 'no-such-origin.git')
    $r = Invoke-Kit $checkScope @('-Packet', 'PKT-02', '-Base', $b0, '-Json')
    $cjOff = try { $r.Text -split "`n" | Where-Object { $_ -notmatch '^check-scope:' } | Out-String | ConvertFrom-Json } catch { $null }
    Assert-That ($r.Code -eq 1 -and $cjOff -and $cjOff.Base -eq $b0 -and @($cjOff.Results | Where-Object { $_.Kind -eq 'OUTSIDE' -and $_.Path -eq 'src/A/evil.ps1' }).Count -eq 1) 'with origin unreachable it keeps the brief''s base, not the moved local ref' $r.Text
    Invoke-Q remote set-url origin $originRepo
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

Write-Host 'github hierarchy (against a stubbed gh)'
$ghTest = Join-Path ([System.IO.Path]::GetTempPath()) "pw-ghh-$([guid]::NewGuid().ToString('n')).ps1"
Set-Content -LiteralPath $ghTest -Value @'
param([string]$Kit)
. (Join-Path $Kit 'skills/packet-board/scripts/PacketWorkflow.ps1')
. (Join-Path $Kit 'skills/packet-board/scripts/providers/github-common.ps1')
$script:PwConfig = @{ repo = 'example/sample' }
# Sub-issue lists by issue number (DbIds), and each issue's parent: an issue object, or an error text.
$script:Subs = @{ '99' = @(1001, 1003, 1008) }
$script:Parents = @{ '2' = @{ number = 57; repository_url = 'https://api.github.com/repos/Example/Sample' }; '4' = @{ number = 12; repository_url = 'https://api.github.com/repos/example/other' }; '8' = @{ number = 99; repository_url = 'https://api.github.com/repos/example/sample' } }
function Invoke-PwGh {
    $line = @($args) -join ' '; $script:GhCalls += , $line
    # As on GitHub, an issue path without a number is not found.
    if ($line -match 'issues//') { Stop-Pw "gh api $line failed: gh: Not Found (HTTP 404)" }
    if ($line -match 'issues/(\d+)/sub_issues\?per_page') { return '[[' + ((@($script:Subs[$Matches[1]]) | Where-Object { $_ } | ForEach-Object { "{`"id`":$_}" }) -join ',') + ']]' }
    if ($line -match 'issues/(\d+)/parent$') {
        $p = $script:Parents[$Matches[1]]
        if ($null -eq $p) { Stop-Pw "gh api $line failed: gh: No parent issue found (HTTP 404)" }
        if ($p -is [string]) { Stop-Pw "gh api $line failed: gh: $p" }
        return ($p | ConvertTo-Json)
    }
    if ($line -match '^api -X POST repos/example/sample/issues/\d+/sub_issues ') { return '' }
    Stop-Pw "unexpected gh call: $line" }
function I([string]$Id, [int]$N) { [pscustomobject]@{ Id = $Id; Number = $N; DbId = 1000 + $N } }
function P([string]$Id, [string]$Parent = '') { [pscustomobject]@{ Id = $Id; Kind = $(if ($Id -like 'H-*') { 'human' } else { 'packet' }); Parent = $(if ($Parent) { $Parent } else { $null }) } }
$items = @{ 'PKT-01' = (I 'PKT-01' 1); 'PKT-02' = (I 'PKT-02' 2); 'PKT-03' = (I 'PKT-03' 3); 'PKT-04' = (I 'PKT-04' 4); 'H-1' = (I 'H-1' 6); 'H-2' = (I 'H-2' 7); 'H-3' = (I 'H-3' 8) }
# PKT-08 is a packet this sync creates (so a dry run calls it new); PKT-09 has no item and won't get one.
$tree = [pscustomobject]@{ Phase = [pscustomobject]@{ Slug = 'phase-1'; Root = [pscustomobject]@{ Level = 'epic'; Ref = '#99' } }; Packets = @((P 'PKT-01'), (P 'PKT-02'), (P 'PKT-03'), (P 'PKT-04'), (P 'H-1' 'PKT-03'), (P 'H-2' 'PKT-09'), (P 'H-3' 'PKT-08'), (P 'H-4' 'PKT-09')) }
$creating = @('PKT-08')
function Show([string]$Name, [scriptblock]$Run) {
    $script:GhCalls = @()
    try { $out = @(& $Run); "$Name=$($out -join ' | ')|posts=$((@($script:GhCalls | Where-Object { $_ -match '-X ' })) -join ' ; ')|reads=$((@($script:GhCalls | Where-Object { $_ -match '/parent$' } | ForEach-Object { ($_ -split '/')[-2] })) -join ',')" }
    catch { "$Name=error:$($_.Exception.Message)" }
}
Show 'gh-dry' { Set-ProvHierarchy -Tree $tree -ItemsById $items -Creating $creating -DryRun }
Show 'gh-dry-force' { Set-ProvHierarchy -Tree $tree -ItemsById $items -Creating $creating -DryRun -Force }
Show 'gh' { Set-ProvHierarchy -Tree $tree -ItemsById $items }
Show 'gh-force' { Set-ProvHierarchy -Tree $tree -ItemsById $items -Force }
$script:Parents['2'] = 'Server Error (HTTP 502)'
Show 'gh-502' { Set-ProvHierarchy -Tree $tree -ItemsById $items }
# Everything in its place: H-1 already a sub-issue of PKT-03's issue, nothing read but the lists.
$script:Subs = @{ '99' = @(1001, 1002, 1003, 1004, 1008); '3' = @(1006) }
Show 'gh-again' { Set-ProvHierarchy -Tree $tree -ItemsById $items }
'@
$r = Invoke-Kit $ghTest @('-Kit', $kit)
$gh = @{}; foreach ($line in ($r.Text -split "`n")) { if ($line -match '^(?<k>gh[\w-]*)=(?<v>.*)$') { $gh[$Matches.k] = $Matches.v } }
$ghGet = { param($k) if ($gh.ContainsKey($k)) { $gh[$k] } else { '' } }
Assert-That ($r.Code -eq 0 -and (& $ghGet 'gh-dry') -match 'note: PKT-02 #2 is under #57, and its place is under epic #99' -and (& $ghGet 'gh-dry') -match 'would put H-1 #6 under PKT-03 #3' -and (& $ghGet 'gh-dry') -match 'note: H-3 #8 is under #99, and its place is under PKT-08 \(new\)' -and (& $ghGet 'gh-dry') -notmatch 'would move' -and (& $ghGet 'gh-dry') -match '\|posts=\|') 'GitHub: a dry run says what it would link and names misplaced issues, a Parent this sync creates as (new), writing nothing' $r.Text
Assert-That ((& $ghGet 'gh-dry-force') -match 'would move PKT-02 #2 under epic #99 \(now under #57\)' -and (& $ghGet 'gh-dry-force') -match 'would move PKT-04 #4 under epic #99 \(now under example/other#12\)' -and (& $ghGet 'gh-dry-force') -match 'would move H-3 #8 under PKT-08 \(new\) \(now under #99\)' -and (& $ghGet 'gh-dry-force') -match '\|posts=\|') 'GitHub: a dry run with -Force lists every move, writing nothing' (& $ghGet 'gh-dry-force')
$missing = "note: H-2 #7 was left where it is: its Parent PKT-09 isn't on the board"
Assert-That ((& $ghGet 'gh-dry') -match "note: H-4 \(new\) would get no parent: its Parent PKT-09 isn't on the board") 'GitHub: a dry run tells a new task whose Parent has no issue that it would get no parent' (& $ghGet 'gh-dry')
Assert-That ((@('gh-dry', 'gh-dry-force', 'gh', 'gh-force') | Where-Object { (& $ghGet $_) -match [regex]::Escape($missing) -and (& $ghGet $_) -notmatch 'PKT-09 \(new\)' }).Count -eq 4) 'GitHub: a Parent packet sync won''t create is named the same way in a dry run, with -Force, and in a real run' $r.Text
Assert-That ((& $ghGet 'gh') -match 'note: PKT-02 #2 is under #57, and its place is under epic #99: sync -Phase phase-1 -Force moves it' -and (& $ghGet 'gh') -match 'note: PKT-04 #4 is under example/other#12' -and (& $ghGet 'gh') -match 'linked H-1 under PKT-03 #3' -and (& $ghGet 'gh') -match "note: H-2 #7 was left where it is: its Parent PKT-09 isn't on the board" -and (& $ghGet 'gh') -match '\|posts=api -X POST repos/example/sample/issues/3/sub_issues -F sub_issue_id=1006\|') 'GitHub: a human task becomes a sub-issue of its Parent packet; an issue under another parent is named, not re-parented, so sync no longer fails on it' (& $ghGet 'gh')
Assert-That ((& $ghGet 'gh-force') -match 'moved PKT-02 under epic #99 \(was under #57\)' -and (& $ghGet 'gh-force') -match 'moved PKT-04 under epic #99 \(was under example/other#12\)' -and (& $ghGet 'gh-force') -match 'issues/99/sub_issues -F sub_issue_id=1002 -F replace_parent=true') 'GitHub: sync -Force moves it, with replace_parent' (& $ghGet 'gh-force')
Assert-That ((& $ghGet 'gh-502') -match '^error:.*HTTP 502') 'GitHub: an error other than 404 reading a parent stops sync' (& $ghGet 'gh-502')
Assert-That ((& $ghGet 'gh-again') -eq "note: H-2 #7 was left where it is: its Parent PKT-09 isn't on the board | note: H-3 #8 was left where it is: its Parent PKT-08 isn't on the board | note: H-4 (new) would get no parent: its Parent PKT-09 isn't on the board|posts=|reads=") 'GitHub: a human task already under its Parent packet''s issue is left alone, and no parent is read' (& $ghGet 'gh-again')
Remove-Item -LiteralPath $ghTest

Write-Host 'azure-boards hierarchy (against an in-memory Azure DevOps)'
# Sync's steps for one phase (Resolve-ProvHierarchy, New-ProvItem for missing items, Set-ProvHierarchy), run
# against tests/azure-boards-fake.ps1, which keeps links, revisions and states the way Azure DevOps does.
$abTest = Join-Path ([System.IO.Path]::GetTempPath()) "pw-ab-$([guid]::NewGuid().ToString('n')).ps1"
Set-Content -LiteralPath $abTest -Value @'
param([string]$Kit)
. (Join-Path $Kit 'skills/packet-board/scripts/PacketWorkflow.ps1')
. (Join-Path $Kit 'skills/packet-board/scripts/providers/github-common.ps1')
. (Join-Path $Kit 'skills/packet-board/scripts/providers/azure-boards.ps1')
. (Join-Path $Kit 'tests/azure-boards-fake.ps1')
function Initialize-PwGhLabels { param($Config, [string[]]$Keys, [switch]$DryRun) , @() }
$tpl = Get-Content -Raw (Join-Path $Kit 'templates/packet-workflow.json') | ConvertFrom-Json -AsHashtable
function New-TestConfig {
    param([hashtable]$Azure = @{})
    $ab = Merge-PwHashtable $tpl.board.azureBoards (Merge-PwHashtable @{ organization = 'https://dev.azure.com/fake'; project = 'Sample' } $Azure)
    Merge-PwHashtable $script:Defaults @{ repo = 'example/sample'; board = @{ provider = 'azure-boards'; azureBoards = $ab } }
}
function Reset-Board { param($Config) $script:FakeAb.Items = @{}; $script:FakeAb.Next = 1; $script:FakeAbCalls.Clear(); $script:AbTrees = @{}; $script:AbFeatures = @{}; $script:AbFeatureTitles = @{}; $script:AbFeaturesPlanned = @{}; $script:AbItemCache = $null; Initialize-Prov -Config $Config }
function P {
    param([string]$Id, [string]$Workstream = '', [string[]]$Deps = @(), [string]$Parent = '')
    $human = $Id -like 'H-*'
    [pscustomobject]@{ Id = $Id; Title = 'Work'; Kind = $(if ($human) { 'human' } else { 'packet' }); Phase = 'phase-1'; Workstream = $(if ($Workstream) { $Workstream } else { $null })
        DependsOn = @($Deps); Parent = $(if ($Parent) { $Parent } else { $null }); InitialStatus = 'Ready'; Priority = 'P1'; Size = $(if ($human) { $null } else { 'M' }); Wave = 'W1'; Target = $null }
}
function Phase {
    param([string]$Line, [string]$Ref, [string]$Slug = 'phase-1', [string]$Title = 'Storefront')
    $root = if ($Line) { [pscustomobject]@{ Level = $(switch ($Line) { 'Epic' { 'epic' } 'Feature' { 'feature' } default { 'story' } }); Ref = $Ref; Line = $Line } } else { $null }
    [pscustomobject]@{ Slug = $Slug; Title = $Title; Path = "docs/plan/$Slug/plan.md"; Root = $root; Roots = @($root | Where-Object { $_ }); Epic = $null; Exists = $true }
}
function Invoke-TestSync {
    <# board.ps1's order: every phase's tree first, then the missing items, then each tree. -Phases pairs a
       phase with its packets: @(@($phase, $packets), …); or pass one -Phase and its -Packets. #>
    param($Phase, $Packets, [object[]]$Phases, [switch]$DryRun, [switch]$Force)
    if (-not $Phases) { $Phases = @(, @($Phase, $Packets)) }
    $items = @{}; foreach ($it in @(Get-ProvItems -Refresh)) { $items[$it.Id] = $it }
    $creating = @(foreach ($pair in $Phases) { foreach ($p in $pair[1]) { if (-not $items[$p.Id]) { $p.Id } } })
    $trees = @(foreach ($pair in $Phases) { Resolve-ProvHierarchy -Phase $pair[0] -Packets $pair[1] })
    if (-not $DryRun) {
        foreach ($pair in $Phases) { foreach ($p in $pair[1]) { if (-not $items[$p.Id]) { $items[$p.Id] = New-ProvItem -Packet $p -Title "$($p.Id) · $($p.Title)" -Body "Packet $($p.Id)" -PhaseSlug $pair[0].Slug -PhaseTitle $pair[0].Title } } }
    }
    @(foreach ($tree in $trees) { Set-ProvHierarchy -Tree $tree -ItemsById $items -Creating $creating -DryRun:$DryRun -Force:$Force })
}
function Get-Tree { param([string[]]$Ids) ($Ids | ForEach-Object { $n = Find-FakeAbItem $_; "$($_)>$(Get-FakeAbParent $n):$($script:FakeAb.Items[$n].fields['System.WorkItemType'])" }) -join ',' }
function Get-ParentId { param([int]$Id) Get-FakeAbTarget (@($script:FakeAb.Items[$Id].relations | Where-Object { $_.rel -eq 'System.LinkTypes.Hierarchy-Reverse' })[0]) }

# 1. An epic root, on a board laid out the old way (every item straight under the epic): a plain sync links
# the new items and names the misplaced ones; -Force moves them.
Reset-Board (New-TestConfig)
$epic = New-FakeAbItem 'Epic' 'Storefront revamp'
[void](New-FakeAbItem 'Feature' 'Payments' -State 'Closed' -Parent $epic)
$payments = New-FakeAbItem 'Feature' 'Payments' -Parent $epic
[void](New-FakeAbItem 'Feature' 'Checkout')
$pkt1 = New-FakeAbItem 'User Story' 'PKT-01 · Core' -Tags 'packet; phase:phase-1' -Parent $epic
[void](New-FakeAbItem 'Task' 'H-1 · Approve keys' -Tags 'packet; human-task; phase:phase-1' -Parent $epic)
[void](New-FakeAbItem 'Feature' 'Checkout' -State 'Removed' -Parent $epic)
$packets = @((P 'PKT-01' 'payments'), (P 'PKT-02' 'Checkout' @('PKT-01')), (P 'H-1' '' @('PKT-01')), (P 'PKT-03' '' @('H-1')), (P 'H-2' '' @('PKT-02')), (P 'H-3'))
$ph = Phase 'Epic' "AB#$epic"
$dry = Invoke-TestSync $ph $packets -DryRun
"s1-dry=$($dry -join ' | ')|writes=$(@(Get-FakeAbWrites).Count)"
$plain = Invoke-TestSync $ph $packets
"s1-plain=$($plain -join ' | ')|tree=$(Get-Tree 'PKT-01', 'PKT-02', 'H-1')"
$mark = $script:FakeAbCalls.Count
$dryForce = Invoke-TestSync $ph $packets -DryRun -Force
"s1-dry-force=$($dryForce -join ' | ')|writes=$(@(Get-FakeAbWrites $mark).Count)"
$out = Invoke-TestSync $ph $packets -Force
"s1=$($out -join ' | ')"
"s1-tree=$(Get-Tree 'PKT-01', 'PKT-02', 'PKT-03', 'H-1', 'H-2', 'H-3')"
"s1-reused=$((Get-ParentId $pkt1) -eq $payments)"
"s1-epic=" + ((@($script:FakeAb.Items[$epic].relations | Where-Object { $_.rel -eq 'System.LinkTypes.Hierarchy-Forward' } | ForEach-Object { $c = $script:FakeAb.Items[(Get-FakeAbTarget $_)]; "$($c.fields['System.WorkItemType']):$($c.fields['System.Title'])" }) | Sort-Object) -join ',')
$mark = $script:FakeAbCalls.Count
$again = Invoke-TestSync $ph $packets
"s1-again=$($again -join ' | ')|writes=$(@(Get-FakeAbWrites $mark).Count)"

# 1b. Two phases under one epic share a workstream's Feature, in one sync and the next.
Reset-Board (New-TestConfig)
$epic = New-FakeAbItem 'Epic' 'Platform'
$two = @(@((Phase 'Epic' "AB#$epic" 'phase-1' 'Alpha'), @((P 'PKT-01' 'Backend'))), @((Phase 'Epic' "AB#$epic" 'phase-2' 'Beta'), @((P 'PKT-02' 'backend'), (P 'PKT-03'))))
$dry = Invoke-TestSync -Phases $two -DryRun
"s1b-dry=$($dry -join ' | ')"
$out = Invoke-TestSync -Phases $two
$mark = $script:FakeAbCalls.Count
$again = Invoke-TestSync -Phases $two
"s1b=$(Get-Tree 'PKT-01', 'PKT-02', 'PKT-03')|features=$(@($script:FakeAb.Items.Values | Where-Object { $_.fields['System.WorkItemType'] -eq 'Feature' } | ForEach-Object { "$($_.fields['System.Title'])[$($_.fields['System.Tags'])]" } | Sort-Object) -join ',')|again=$(@($again).Count)/$(@(Get-FakeAbWrites $mark).Count)"

# 1b'. A board kept in another layout on purpose: a plain sync (the dispatcher's) creates no Feature that
# nothing would go under, so it writes nothing at all; -Force then builds the tree.
Reset-Board (New-TestConfig)
$epic = New-FakeAbItem 'Epic' 'Kept'
[void](New-FakeAbItem 'User Story' 'PKT-01 · Api' -Tags 'packet' -Parent $epic)
[void](New-FakeAbItem 'User Story' 'PKT-02 · Web' -Tags 'packet' -Parent $epic)
$kept = @((P 'PKT-01' 'Backend'), (P 'PKT-02'))
$mark = $script:FakeAbCalls.Count
$plain = Invoke-TestSync (Phase 'Epic' "AB#$epic") $kept
"s1k=$($plain -join ' | ')|writes=$(@(Get-FakeAbWrites $mark).Count)"
$forced = Invoke-TestSync (Phase 'Epic' "AB#$epic") $kept -Force
"s1k-force=$(Get-Tree 'PKT-01', 'PKT-02')|$($forced -join ' | ')"

# 1b''. An item of an older type (a packet made a Task) with no parent: neither a plain sync nor -Force
# creates the Feature it can't go under.
Reset-Board (New-TestConfig)
$epic = New-FakeAbItem 'Epic' 'Old types'
[void](New-FakeAbItem 'Task' 'PKT-01 · Api' -Tags 'packet')
$mark = $script:FakeAbCalls.Count
$plain = Invoke-TestSync (Phase 'Epic' "AB#$epic") @((P 'PKT-01' 'Backend'))
$forced = Invoke-TestSync (Phase 'Epic' "AB#$epic") @((P 'PKT-01' 'Backend')) -Force
"s1t=$($plain -join ' | ')|$($forced -join ' | ')|writes=$(@(Get-FakeAbWrites $mark).Count)"

# 1c. An item changed on the board between sync's read and its write is not overwritten: the move fails.
Reset-Board (New-TestConfig)
$epic = New-FakeAbItem 'Epic' 'Stale'
$pkt1 = New-FakeAbItem 'User Story' 'PKT-01 · Core' -Tags 'packet' -Parent $epic
$script:StaleId = $pkt1
# Someone edits the item right after sync reads it.
function Get-PwAbWorkItem { param([int]$Id) $wi = Invoke-PwAb -Path "_apis/wit/workitems/${Id}?`$expand=relations"; if ($Id -eq $script:StaleId) { $script:FakeAb.Items[$Id].rev++ }; $wi }
try { [void](Invoke-TestSync (Phase 'Epic' "AB#$epic") @((P 'PKT-01' 'Backend')) -Force); 's1c=none' } catch { "s1c=$($_.Exception.Message)|parent=$(Get-FakeAbParent $pkt1)" }
$script:StaleId = 0

# 2. A story root: the packets are its tasks, with the task states.
Reset-Board (New-TestConfig)
$story = New-FakeAbItem 'User Story' 'Export orders as CSV'
$out = Invoke-TestSync (Phase 'User Story' "AB#$story") @((P 'PKT-01'), (P 'PKT-02' '' @('PKT-01')), (P 'H-1' '' @('PKT-02')))
"s2=$($out -join ' | ')"
"s2-tree=$(Get-Tree 'PKT-01', 'PKT-02', 'H-1')"
Set-ProvFields -Item (@(Get-ProvItems -Refresh) | Where-Object { $_.Id -eq 'PKT-01' }) -Fields @{ Status = 'Ready to merge' }
$back = @(Get-ProvItems -Refresh) | Where-Object { $_.Id -eq 'PKT-01' }
"s2-status=$($back.Status)|state=$($script:FakeAb.Items[$back.Number].fields['System.State'])|tags=$($script:FakeAb.Items[$back.Number].fields['System.Tags'])"
$noMap = New-TestConfig; $noMap.board.azureBoards.Remove('taskStatusMap')
Reset-Board $noMap
$story = New-FakeAbItem 'User Story' 'Export'
try { [void](Resolve-ProvHierarchy -Phase (Phase 'User Story' "AB#$story") -Packets @((P 'PKT-01'))); 's2-nomap=none' } catch { "s2-nomap=$($_.Exception.Message)" }

# 3. A feature root, with an item left over from when the root was a story, and roots that don't fit.
Reset-Board (New-TestConfig)
$epic = New-FakeAbItem 'Epic' 'Big'
$feature = New-FakeAbItem 'Feature' 'Search' -Parent $epic
[void](New-FakeAbItem 'Task' 'PKT-02 · Left over' -Tags 'packet')
$out = Invoke-TestSync (Phase 'Feature' "AB#$feature") @((P 'PKT-01'), (P 'PKT-02'), (P 'H-1' '' @('PKT-02')), (P 'H-2' '' @('PKT-01')))
"s3=$($out -join ' | ')"
"s3-tree=$(Get-Tree 'PKT-01', 'H-2', 'PKT-02', 'H-1')"
foreach ($case in @(@{ Name = 'wrong-type'; Line = 'Feature'; Ref = "AB#$epic" }, @{ Name = 'packet-root'; Line = 'User Story'; Ref = "AB#$(Find-FakeAbItem 'PKT-01')" }, @{ Name = 'missing'; Line = 'Epic'; Ref = 'AB#999' })) {
    $mark = $script:FakeAbCalls.Count
    try { [void](Resolve-ProvHierarchy -Phase (Phase $case.Line $case.Ref) -Packets @((P 'PKT-09'))); "s3-$($case.Name)=none" } catch { "s3-$($case.Name)=$($_.Exception.Message)|writes=$(@(Get-FakeAbWrites $mark).Count)" }
}

# 4. Basic: Epic > Issue > Task, no features.
$basicMap = @{ Backlog = @{ state = 'To Do' }; Ready = @{ state = 'To Do'; tag = 'status:ready' }; 'In progress' = @{ state = 'Doing' }; 'In review' = @{ state = 'Doing'; tag = 'status:in-review' }
    'Ready to merge' = @{ state = 'Doing'; tag = 'status:ready-to-merge' }; 'Needs human' = @{ state = 'Doing'; tag = 'status:needs-human' }; Done = @{ state = 'Done' } }
Reset-Board (New-TestConfig @{ featureWorkItemType = ''; workItemType = 'Issue'; statusMap = $basicMap })
$epic = New-FakeAbItem 'Epic' 'Basic epic'
[void](Invoke-TestSync (Phase 'Epic' "AB#$epic") @((P 'PKT-01' 'Ignored'), (P 'H-1' '' @('PKT-01'))))
"s4-tree=$(Get-Tree 'PKT-01', 'H-1')"
# 4b. Tags. The fake, like Azure DevOps, merges an 'add' on System.Tags into the tags already there, so these
# fail if a write adds the new list rather than replacing the old one. Each status keeps only its own tag.
function Get-TagSet { param([int]$Id) (@(Get-PwAbTags $script:FakeAb.Items[$Id].fields) | Sort-Object) -join ',' }
$pkt = @(Get-ProvItems -Refresh) | Where-Object { $_.Id -eq 'PKT-01' }
$walk = foreach ($s in 'In review', 'Ready to merge', 'In progress', 'Needs human', 'Done') {
    Set-ProvFields -Item $pkt -Fields @{ Status = $s }
    $back = @(Get-ProvItems -Refresh) | Where-Object { $_.Id -eq 'PKT-01' }
    "$s>$($back.Status)[$(@(Get-PwAbTags $script:FakeAb.Items[$pkt.Number].fields | Where-Object { $_ -like 'status:*' }) -join ',')]"
}
"s4-walk=$($walk -join ' ')|tags=$(Get-TagSet $pkt.Number)"
# An item that already carries several status tags (as earlier writes left them on a real board): a status
# change leaves one. Then a retag (sync's Update-ProvItem) replaces the size, wave and phase tags.
$stale = New-FakeAbItem 'Issue' 'PKT-09 · Stale' -Tags 'packet; size:S; status:ready; status:in-review; status:ready-to-merge; wave:W0' -State 'Doing' -Parent $epic
Set-ProvFields -Item (@(Get-ProvItems -Refresh) | Where-Object { $_.Id -eq 'PKT-09' }) -Fields @{ Status = 'Ready to merge' }
"s4-stale=$(Get-TagSet $stale)"
$moved = [pscustomobject]@{ Priority = $null; Size = 'L'; Wave = 'W2'; Target = $null }
Update-ProvItem -Item (@(Get-ProvItems -Refresh) | Where-Object { $_.Id -eq 'PKT-09' }) -Packet $moved -Title 'PKT-09 · Stale' -Body 'Packet PKT-09' -PhaseSlug 'phase-2'
"s4-retag=$(Get-TagSet $stale)"
$plain = New-FakeAbItem 'Issue' 'Not a packet' -Tags 'a; b'
[void](Invoke-PwAb -Method PATCH -Path "_apis/wit/workitems/$plain" -Body @(@{ op = 'add'; path = '/fields/System.Tags'; value = 'B; c' }) -ContentType 'application/json-patch+json')
$added = Get-TagSet $plain
[void](Invoke-PwAb -Method PATCH -Path "_apis/wit/workitems/$plain" -Body @(@{ op = 'replace'; path = '/fields/System.Tags'; value = 'c' }) -ContentType 'application/json-patch+json')
"s4-fake-tags=$added|$(Get-TagSet $plain)"
try { [void](Resolve-ProvHierarchy -Phase (Phase 'Feature' "AB#$epic") -Packets @()); 's4-feature=none' } catch { "s4-feature=$($_.Exception.Message)" }
Reset-Board (New-TestConfig @{ taskWorkItemType = 'user story' })
$epic = New-FakeAbItem 'Epic' 'One type, two levels'
try { [void](Resolve-ProvHierarchy -Phase (Phase 'Epic' "AB#$epic") -Packets @((P 'PKT-01'))); 's4-same=none' } catch { "s4-same=$($_.Exception.Message)" }
try { [void](Resolve-ProvHierarchy -Phase (Phase '' '') -Packets @((P 'PKT-01'))); 's4-same-unrooted=ok' } catch { "s4-same-unrooted=$($_.Exception.Message)" }
# A Basic install from before the hierarchy: no featureWorkItemType, so the default Feature, which Basic lacks.
$oldBasic = New-TestConfig @{ workItemType = 'Issue'; statusMap = $basicMap }
Reset-Board $oldBasic
$script:FakeAb.States.Remove('Feature')
$epic = New-FakeAbItem 'Epic' 'Old basic'
$mark = $script:FakeAbCalls.Count
try { [void](Invoke-TestSync (Phase 'Epic' "AB#$epic") @((P 'PKT-01'))); 's4-old-basic=none' } catch { "s4-old-basic=$($_.Exception.Message)|writes=$(@(Get-FakeAbWrites $mark).Count)" }
$script:FakeAb.States['Feature'] = @('New', 'Active', 'Resolved', 'Closed', 'Removed')
# A human task type that is no level's type still sits under the story it unblocks.
Reset-Board (New-TestConfig @{ humanWorkItemType = 'Approval' })
$feature = New-FakeAbItem 'Feature' 'Search'
$out = Invoke-TestSync (Phase 'Feature' "AB#$feature") @((P 'H-1'), (P 'PKT-01' '' @('H-1')))
"s4-approval=$(Get-Tree 'PKT-01', 'H-1')|$($out -join ' | ')"

# 7. A human task's Parent line names its story, over the one it unblocks or follows; an item already under
# another story stays there until -Force. Under a story root, where packets are tasks too, the line has no effect.
Reset-Board (New-TestConfig)
$feature = New-FakeAbItem 'Feature' 'Search'
$ph7 = Phase 'Feature' "AB#$feature"
$out = Invoke-TestSync $ph7 @((P 'PKT-01'), (P 'PKT-02'), (P 'H-1' '' @('PKT-01') 'PKT-02'), (P 'H-2' '' @() 'PKT-01'))
"s7=$(Get-Tree 'PKT-01', 'PKT-02', 'H-1', 'H-2')|$($out -join ' | ')"
$changed = @((P 'PKT-01'), (P 'PKT-02'), (P 'H-1' '' @('PKT-01') 'PKT-01'), (P 'H-2' '' @() 'PKT-01'))
$plain = Invoke-TestSync $ph7 $changed
"s7-plain=$(Get-Tree 'H-1')|$($plain -join ' | ')"
$forced = Invoke-TestSync $ph7 $changed -Force
"s7-force=$(Get-Tree 'H-1')|$($forced -join ' | ')"
$story = New-FakeAbItem 'User Story' 'Small'
$out = Invoke-TestSync (Phase 'User Story' "AB#$story" 'phase-2' 'Small') @((P 'PKT-05'), (P 'H-5' '' @('PKT-05') 'PKT-05'))
"s7-story=$(Get-Tree 'H-5')|$($out -join ' | ')"

# 7b. A Parent packet with no item that this sync won't create (another phase, or no file): a dry run, a
# plain sync and -Force all leave the task and say why, the same way. One this sync creates is "(new)".
Reset-Board (New-TestConfig)
$feature = New-FakeAbItem 'Feature' 'Search'
$ph7b = Phase 'Feature' "AB#$feature"
[void](Invoke-TestSync $ph7b @((P 'PKT-01'), (P 'H-1' '' @('PKT-01'))))
$gone = @((P 'PKT-01'), (P 'H-1' '' @('PKT-01') 'PKT-20'), (P 'H-2' '' @() 'PKT-20'))
$dry = Invoke-TestSync $ph7b $gone -DryRun -Force
$plain = Invoke-TestSync $ph7b $gone
$forced = Invoke-TestSync $ph7b $gone -Force
"s7b=$(Get-Tree 'H-1')|$($dry -join ' | ')||$($plain -join ' | ')||$($forced -join ' | ')"
$coming = @((P 'PKT-01'), (P 'PKT-21'), (P 'H-1' '' @('PKT-01') 'PKT-21'))
"s7b-new=$((Invoke-TestSync $ph7b $coming -DryRun -Force) -join ' | ')"
# 7c. A Parent packet another phase creates in this sync, under a story root, so as a Task: the dry run
# refuses the move the way the real run does, rather than promising it.
Reset-Board (New-TestConfig)
$feature = New-FakeAbItem 'Feature' 'Search'
$small = New-FakeAbItem 'User Story' 'Small'
[void](Invoke-TestSync (Phase 'Feature' "AB#$feature") @((P 'PKT-01'), (P 'H-1' '' @('PKT-01'))))
$two = @(@((Phase 'Feature' "AB#$feature"), @((P 'PKT-01'), (P 'H-1' '' @('PKT-01') 'PKT-20'))), @((Phase 'User Story' "AB#$small" 'phase-2' 'Small'), @((P 'PKT-20'))))
$dry = Invoke-TestSync -Phases $two -DryRun -Force
$forced = Invoke-TestSync -Phases $two -Force
"s7c=$(Get-Tree 'H-1')|$($dry -join ' | ')||$($forced -join ' | ')"

# 8. Claims as work item comments, judged by the board's clock (the fake's, hours from the local one).
# Comments come back two to a page, so every read follows the continuation token.
Reset-Board (New-TestConfig)
$script:FakeAb.Comments = @{}; $script:FakeAb.CommentPage = 2
$L = 30
function Claim {
    param([string]$Id, [switch]$Force)
    $r = Invoke-PwClaim -Ref $script:ClaimRef -ClaimId $Id -LeaseMinutes $L -Force:$Force
    if ($r.Result -ne 'HOLD') { return "LOST:$($r.ClaimId)" }
    "HOLD:$($r.ClaimId):$(if ($r.Renewed) { 'renewed' } else { 'kept' })$(if ($r.Lapsed) { ':lapsed' })"
}
function Posts { param([int]$Item, [string]$Id) @(Get-FakeAbComments $Item | Where-Object { $_.text -match "^``packet:claim $([regex]::Escape($Id))``" }).Count }
$wi = New-FakeAbItem 'User Story' 'PKT-01 · Core' -Tags 'packet'
$script:ClaimRef = [string]$wi
$script:FakeAb.Clock = [DateTimeOffset]::UtcNow.AddHours(-3)
$first = Claim 'session-a'
$rev0 = $script:FakeAb.Items[$wi].rev; $mark = $script:FakeAbCalls.Count
$checks = @(foreach ($m in 1, 4, 4) { Move-FakeAbClock -Minutes $m; Claim 'session-a' })
$commentWrites = @($script:FakeAbCalls | Select-Object -Skip $mark | Where-Object { $_ -match '^(POST|DELETE) .*/comments' }).Count
"c-kept=$first|$($checks -join ',')|posts=$(Posts $wi 'session-a')|revs=$($script:FakeAb.Items[$wi].rev - $rev0)|writes=$commentWrites|live=$(@((Get-PwLiveClaims -Ref $script:ClaimRef -LeaseMinutes $L).Claims).Count)"
# 10m06s after the claim, a third of the lease is gone: the next check renews, and the one after keeps it.
Move-FakeAbClock -Minutes 1.1
$due = Claim 'session-a'
Move-FakeAbClock -Minutes 1
"c-due=$due|$(Claim 'session-a')|posts=$(Posts $wi 'session-a')"
# A forged older claim from someone untrusted counts for nothing; a competitor loses and leaves no comment.
[void](Add-FakeAbComment -Id $wi -Text '`packet:claim session-m` forged' -By 'mallory@example.com' -At $script:FakeAb.Clock.AddMinutes(-15))
$b = Claim 'session-b'
"c-competitor=$b|$(Claim 'session-a')|b-posts=$(Posts $wi 'session-b')|a-posts=$(Posts $wi 'session-a')"
# The lease lapses: a competitor takes over, and the old holder's check and its forced renewal both lose.
Move-FakeAbClock -Minutes 31
$taken = Claim 'session-b'
"c-lapse=$taken|$(Claim 'session-a')|$(Claim 'session-a' -Force)|a-posts=$(Posts $wi 'session-a')|b-posts=$(Posts $wi 'session-b')"
# The new holder's renewal is due, and the old holder claims while it runs (after its post, before its read).
Move-FakeAbClock -Minutes 11
$script:FakeAb.OnComment = { param($c) $script:Race = Claim 'session-a' }
$renew = Claim 'session-b'
"c-race-due=$renew|$($script:Race)|holds=$(@($renew, $script:Race | Where-Object { $_ -like 'HOLD*' }).Count)|a-posts=$(Posts $wi 'session-a')|b-posts=$(Posts $wi 'session-b')"
"c-release=$(Remove-PwClaim -Ref $script:ClaimRef -ClaimId 'session-a')|$(Posts $wi 'session-a')|$(Posts $wi 'session-b')|$(Remove-PwClaim -Ref $script:ClaimRef -ClaimId 'session-b')|$(Posts $wi 'session-b')"
# After a lapse, two sessions post in the same second, each inside the other's check: the lower comment id
# holds, whichever of them started first.
$wi2 = New-FakeAbItem 'User Story' 'PKT-02 · Api' -Tags 'packet'
$script:ClaimRef = [string]$wi2
[void](Claim 'session-x')
Move-FakeAbClock -Minutes 40
$script:FakeAb.OnComment = { param($c) $script:Race = Claim 'session-y' }
$x = Claim 'session-x'
$one = "$x|$($script:Race)"
[void](Remove-PwClaim -Ref $script:ClaimRef -ClaimId 'session-x')
[void](Claim 'session-x')
Move-FakeAbClock -Minutes 40
$script:FakeAb.OnComment = { param($c) $script:Race = Claim 'session-x' }
$y = Claim 'session-y'
"c-race-lapsed=$one|$y|$($script:Race)|x-posts=$(Posts $wi2 'session-x')|y-posts=$(Posts $wi2 'session-y')"
# The board's clock five hours ahead of the local one: renewal still follows the board's.
$wi3 = New-FakeAbItem 'User Story' 'PKT-03 · Web' -Tags 'packet'
$script:ClaimRef = [string]$wi3
$script:FakeAb.Clock = [DateTimeOffset]::UtcNow.AddHours(5)
$s = @((Claim 'session-s'), $(Move-FakeAbClock -Minutes 5; Claim 'session-s'), $(Move-FakeAbClock -Minutes 6; Claim 'session-s'))
"c-skew-ahead=$($s -join ',')|live=$(@((Get-PwLiveClaims -Ref $script:ClaimRef -LeaseMinutes $L).Claims).Count)"
# A losing claim comment left behind (its delete failed): neither a check nor -Force turns it into a hold
# once the claim that beat it has aged out. The holder's due renewal loses to it, so it defers: it keeps
# the hold on its newest comment and renews once the left-behind one has aged out (or been released).
$wi4 = New-FakeAbItem 'User Story' 'PKT-04 · Ops' -Tags 'packet'
$script:ClaimRef = [string]$wi4
[void](Claim 'session-a')
[void](Add-FakeAbComment -Id $wi4 -Text '`packet:claim session-b` left behind' -At $script:FakeAb.Clock.AddMinutes(5))
$seen = @(foreach ($m in 11, 11, 9) { Move-FakeAbClock -Minutes $m; Claim 'session-a' })
Move-FakeAbClock -Minutes 3
$left = @((Claim 'session-b' -Force), (Claim 'session-b'), (Claim 'session-a'))
$deferred = (Invoke-PwClaim -Ref $script:ClaimRef -ClaimId 'session-a' -LeaseMinutes $L).Deferred
$aPosts = Posts $wi4 'session-a'
Move-FakeAbClock -Minutes 2
$late = Claim 'session-a'
Move-FakeAbClock -Minutes 5
"c-leftover=$($seen -join ',')|$($left -join ',')|deferred=$deferred|a-posts=$aPosts|$late|$(Claim 'session-a')|$(Claim 'session-b' -Force)"
# Deferred too long: with a minute or less left, the renewal that loses is LOST.
$wi5 = New-FakeAbItem 'User Story' 'PKT-05 · Late' -Tags 'packet'
$script:ClaimRef = [string]$wi5
[void](Claim 'session-a')
[void](Add-FakeAbComment -Id $wi5 -Text '`packet:claim session-b` left behind' -At $script:FakeAb.Clock.AddMinutes(3.7))
Move-FakeAbClock -Minutes 4; [void](Claim 'session-a' -Force)
Move-FakeAbClock -Minutes 29.6
"c-leftover-late=$(Claim 'session-a')|$(Claim 'session-a')"
# The renewal stalls past the lease between its post and its read: the lease is measured again, so LOST.
$wi6 = New-FakeAbItem 'User Story' 'PKT-06 · Slow' -Tags 'packet'
$script:ClaimRef = [string]$wi6
[void](Claim 'session-a')
[void](Add-FakeAbComment -Id $wi6 -Text '`packet:claim session-b` left behind' -At $script:FakeAb.Clock.AddMinutes(5))
foreach ($m in 11, 11, 12) { Move-FakeAbClock -Minutes $m; [void](Claim 'session-a') }
$script:FakeAb.OnComment = { param($c) Move-FakeAbClock -Minutes 20 }
"c-leftover-stall=$(Claim 'session-a')"
# A winner the first read didn't see (a real claim, older than ours, that shows up only after our post) is
# never taken for a left-behind one.
$wi7 = New-FakeAbItem 'User Story' 'PKT-07 · Late view' -Tags 'packet'
$script:ClaimRef = [string]$wi7
[void](Claim 'session-a')
Move-FakeAbClock -Minutes 12
$script:FakeAb.OnComment = { param($c) [void](Add-FakeAbComment -Id $wi7 -Text '`packet:claim session-b` late' -At $script:FakeAb.Clock.AddMinutes(-13)) }
"c-late-view=$(Claim 'session-a')|$(Claim 'session-b')"
$script:FakeAb.CommentPage = 200

# 5. Setup checks each level's type, and the task type against its own map.
Reset-Board (New-TestConfig)
"setup=$((Initialize-ProvBoard) -join ' | ')"
Reset-Board $noMap
"setup-nomap=$((Initialize-ProvBoard) -join ' | ')"

# 6. The config's hierarchy keys.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "pw-abcfg-$([guid]::NewGuid().ToString('n'))"
New-Item -ItemType Directory -Path $tmp | Out-Null
Push-Location $tmp
try {
    & git init -q .
    foreach ($case in @(@{ Name = 'template'; Azure = @{} }, @{ Name = 'same-type'; Azure = @{ taskWorkItemType = 'user story' } }, @{ Name = 'task-map'; Azure = @{ taskStatusMap = @{ 'Ready to merge' = @{ state = '' } } } })) {
        $c = @{ repo = 'example/sample'; board = @{ provider = 'azure-boards'; azureBoards = (Merge-PwHashtable $tpl.board.azureBoards (Merge-PwHashtable @{ organization = 'https://dev.azure.com/fake'; project = 'Sample' } $case.Azure)) } }
        $f = Join-Path $tmp "$($case.Name).json"
        Set-Content -LiteralPath $f -Value ($c | ConvertTo-Json -Depth 10)
        try { [void](Get-PwConfig -Path $f); "cfg-$($case.Name)=ok" } catch { "cfg-$($case.Name)=$($_.Exception.Message)" }
    }
}
finally { Pop-Location; Remove-Item -Recurse -Force -LiteralPath $tmp }
'@
$r = Invoke-Kit $abTest @('-Kit', $kit)
$ab = @{}; foreach ($line in ($r.Text -split "`n")) { if ($line -match '^(?<k>[\w-]+)=(?<v>.*)$') { $ab[$Matches.k] = $Matches.v } }
$abGet = { param($k) if ($ab.ContainsKey($k)) { $ab[$k] } else { '' } }
Assert-That ($r.Code -eq 0) 'the hierarchy scenarios run' $r.Text
Assert-That ((& $abGet 's1-dry') -match "would create Feature 'Checkout' under AB#1" -and (& $abGet 's1-dry') -match "would create Feature 'Storefront' under AB#1" -and (& $abGet 's1-dry') -match 'would put PKT-02 \(new\) under Feature ''Checkout'' \(new\)' -and (& $abGet 's1-dry') -match "note: PKT-01 AB#5 is under AB#1, and its place is under Feature 'Payments' AB#3: sync -Phase phase-1 -Force moves it" -and (& $abGet 's1-dry') -notmatch 'would move' -and (& $abGet 's1-dry') -match '\|writes=0$') 'a dry run says which features it would create and what it would link, names misplaced items, and writes nothing' (& $abGet 's1-dry')
Assert-That ((& $abGet 's1-plain') -match '\|tree=PKT-01>Storefront revamp:User Story,PKT-02>Checkout:User Story,H-1>Storefront revamp:Task$' -and (& $abGet 's1-plain') -match 'note: H-1 AB#6 is under AB#1' -and (& $abGet 's1-plain') -notmatch 'moved') 'without -Force, sync moves nothing (the dispatcher''s sync never moves an item): it links new items and names the misplaced' (& $abGet 's1-plain')
Assert-That ((& $abGet 's1-dry-force') -match "would move PKT-01 AB#5 under Feature 'Payments' AB#3 \(now under AB#1\)" -and (& $abGet 's1-dry-force') -match 'would move H-1 AB#6 under PKT-03 AB#\d+ \(now under AB#1\)' -and (& $abGet 's1-dry-force') -match '\|writes=0$') 'a dry run with -Force lists every move, and writes nothing' (& $abGet 's1-dry-force')
Assert-That ((& $abGet 's1-tree') -eq 'PKT-01>Payments:User Story,PKT-02>Checkout:User Story,PKT-03>Storefront:User Story,H-1>PKT-03:Task,H-2>PKT-02:Task,H-3>none:Task') 'under an epic: a feature per workstream (none: the phase''s name), packets as its stories, a human task under the story it unblocks or follows' "$(& $abGet 's1-tree')`n$(& $abGet 's1')"
Assert-That ((& $abGet 's1-reused') -eq 'True' -and (& $abGet 's1-epic') -eq 'Feature:Checkout,Feature:Checkout,Feature:Payments,Feature:Payments,Feature:Storefront') 'an open feature under the epic with the workstream''s name is reused (not a closed one, a Removed one, nor one elsewhere), and only features are left under the epic' "$(& $abGet 's1-reused') $(& $abGet 's1-epic')"
Assert-That ((& $abGet 's1') -match 'moved PKT-01 AB#5 under Feature ''Payments'' AB#3 \(was under AB#1\)' -and (& $abGet 's1') -match 'moved H-1 AB#6 under PKT-03 AB#\d+ \(was under AB#1\)' -and (& $abGet 's1') -match 'note: H-3 \(type Task\) has no User Story to sit under') 'sync -Force says what it moved, and why a human task has no place' (& $abGet 's1')
Assert-That ((& $abGet 's1-again') -match '^note: H-3 [^|]*\|writes=0$') 'a second sync changes nothing' (& $abGet 's1-again')
Assert-That ((& $abGet 's1b') -eq 'PKT-01>Backend:User Story,PKT-02>Backend:User Story,PKT-03>Beta:User Story|features=Backend[],Beta[phase:phase-2]|again=0/0' -and ([regex]::Matches((& $abGet 's1b-dry'), "would create Feature 'Backend'")).Count -eq 1) 'phases under one epic share a workstream''s Feature (one, untagged; a dry run plans it once), and the next sync changes nothing' "$(& $abGet 's1b')`n$(& $abGet 's1b-dry')"
Assert-That ((& $abGet 's1k') -match "note: PKT-01 AB#2 is under AB#1, and its place is under Feature 'Backend' \(new\)" -and (& $abGet 's1k') -notmatch 'created' -and (& $abGet 's1k') -match '\|writes=0$' -and (& $abGet 's1k-force') -match '^PKT-01>Backend:User Story,PKT-02>Storefront:User Story\|created Feature') 'on a board kept in another layout, a plain sync creates no empty Feature and writes nothing; -Force builds the tree' "$(& $abGet 's1k')`n$(& $abGet 's1k-force')"
Assert-That ((& $abGet 's1t') -match '^note: PKT-01 AB#2 is of type Task, but its place under Feature ''Backend'' \(new\) takes a work item of type User Story' -and (& $abGet 's1t') -notmatch 'created' -and (& $abGet 's1t') -match '\|writes=0$') 'an item of an older type gets no empty Feature, with or without -Force' (& $abGet 's1t')
Assert-That ((& $abGet 's1c') -match 'TF26071' -and (& $abGet 's1c') -match '\|parent=Stale$') 'a move whose revision test fails stops sync and leaves the item where it was' (& $abGet 's1c')
Assert-That ((& $abGet 's2-tree') -eq 'PKT-01>Export orders as CSV:Task,PKT-02>Export orders as CSV:Task,H-1>Export orders as CSV:Task') 'under a story: the packets and human tasks are its tasks' "$(& $abGet 's2-tree')`n$(& $abGet 's2')"
Assert-That ((& $abGet 's2-status') -match '^Ready to merge\|state=Active\|tags=[^|]*status:ready-to-merge' -and (& $abGet 's2-status') -notmatch 'status:ready(;|$)') 'a task packet moves through the task states (taskStatusMap): Ready to merge is Active plus its tag' (& $abGet 's2-status')
Assert-That ((& $abGet 's2-nomap') -match 'of type Task, which has no state Resolved' -and (& $abGet 's2-nomap') -match 'taskStatusMap') 'a story root without a task status map that fits stops sync before it writes' (& $abGet 's2-nomap')
Assert-That ((& $abGet 's3-tree') -eq 'PKT-01>Search:User Story,H-2>PKT-01:Task,PKT-02>none:Task,H-1>none:Task' -and (& $abGet 's3') -match 'note: PKT-02 AB#3 is of type Task, but its place under AB#2 takes a work item of type User Story' -and (& $abGet 's3') -match 'note: H-1 was left where it is: PKT-02 AB#3, the story it belongs under, is of type Task') 'under a feature: packets as its stories; an item of the wrong type, and a task under it, are left alone and named' "$(& $abGet 's3-tree')`n$(& $abGet 's3')"
Assert-That ((& $abGet 's3-wrong-type') -match 'says \*\*Feature:\*\* AB#1, but AB#1 is of type Epic' -and (& $abGet 's3-packet-root') -match 'is a packet''s own item' -and (& $abGet 's3-missing') -match 'AB#999|999 does not exist' -and (& $abGet 's3-wrong-type') -match 'writes=0$' -and (& $abGet 's3-packet-root') -match 'writes=0$') 'a root of the wrong type, a packet''s own item or a missing item stops sync, having written nothing' "$(& $abGet 's3-wrong-type')`n$(& $abGet 's3-packet-root')`n$(& $abGet 's3-missing')"
Assert-That ((& $abGet 's4-tree') -eq 'PKT-01>Basic epic:Issue,H-1>PKT-01:Task' -and (& $abGet 's4-feature') -match 'featureWorkItemType is empty') 'a process without features (Basic): packets straight under the epic, and a Feature line is refused' "$(& $abGet 's4-tree')`n$(& $abGet 's4-feature')"
Assert-That ((& $abGet 's4-fake-tags') -eq 'a,b,c|c') 'the fake Azure DevOps merges an ''add'' on System.Tags (ignoring case) and lets ''replace'' set them' (& $abGet 's4-fake-tags')
Assert-That ((& $abGet 's4-walk') -eq 'In review>In review[status:in-review] Ready to merge>Ready to merge[status:ready-to-merge] In progress>In progress[] Needs human>Needs human[status:needs-human] Done>Done[]|tags=packet,phase:phase-1,size:M,wave:W1') 'each status change leaves only the new status''s tag (none for an untagged status) and keeps the other tags' (& $abGet 's4-walk')
Assert-That ((& $abGet 's4-stale') -eq 'packet,size:S,status:ready-to-merge,wave:W0') 'a status change clears every stale status tag an item already carries' (& $abGet 's4-stale')
Assert-That ((& $abGet 's4-retag') -eq 'packet,phase:phase-2,size:L,status:ready-to-merge,wave:W2') 'a sync update replaces the old size, wave and phase tags rather than adding to them' (& $abGet 's4-retag')
Assert-That ((& $abGet 's4-old-basic') -match "no work item type 'Feature'" -and (& $abGet 's4-old-basic') -match 'featureWorkItemType' -and (& $abGet 's4-old-basic') -match '\|writes=0$') 'an older Basic config under an epic stops before writing, and says to set featureWorkItemType' (& $abGet 's4-old-basic')
Assert-That ((& $abGet 's4-approval') -match '^PKT-01>Search:User Story,H-1>PKT-01:Approval\|' -and (& $abGet 's4-approval') -notmatch 'note:') 'a human task type outside the levels sits under the story it unblocks' (& $abGet 's4-approval')
Assert-That ((& $abGet 's7') -match '^PKT-01>Search:User Story,PKT-02>Search:User Story,H-1>PKT-02:Task,H-2>PKT-01:Task\|' -and (& $abGet 's7') -notmatch 'note:') 'a Parent line puts a human task under that story, over the one it unblocks, and gives a task with no dependencies a place' (& $abGet 's7')
Assert-That ((& $abGet 's7-plain') -match '^H-1>PKT-02:Task\|note: H-1 AB#\d+ is under AB#\d+, and its place is under PKT-01 AB#\d+: sync -Phase phase-1 -Force moves it' -and (& $abGet 's7-force') -match '^H-1>PKT-01:Task\|moved H-1 AB#\d+ under PKT-01 AB#\d+ \(was under AB#\d+\)') 'a changed Parent line moves the task only with -Force' "$(& $abGet 's7-plain')`n$(& $abGet 's7-force')"
Assert-That ((& $abGet 's7b') -match '^H-1>PKT-01:Task\|' -and ([regex]::Matches((& $abGet 's7b'), "note: H-1 AB#\d+ was left where it is: its Parent PKT-20 isn't on the board")).Count -eq 3 -and (& $abGet 's7b') -notmatch 'Force moves it|PKT-20 \(new\)|would move') 'a Parent packet sync won''t create: the dry run, a plain sync and -Force all say it isn''t on the board, and promise no move' (& $abGet 's7b')
Assert-That ((& $abGet 's7b') -match "note: H-2 \(new\) would get no parent: its Parent PKT-20 isn't on the board") 'a dry run tells a new task whose Parent has no item that it would get no parent' (& $abGet 's7b')
Assert-That ((& $abGet 's7c') -match '^H-1>PKT-01:Task\|' -and (& $abGet 's7c') -match 'note: H-1 was left where it is: PKT-20 \(new\), the story it belongs under, is of type Task, not User Story' -and (& $abGet 's7c') -match 'note: H-1 was left where it is: PKT-20 AB#\d+, the story it belongs under, is of type Task, not User Story' -and (& $abGet 's7c') -notmatch 'would move H-1') 'a Parent packet another phase creates as a Task: the dry run names the type clash the real run hits, and promises no move' (& $abGet 's7c')
Assert-That ((& $abGet 's7b-new') -match 'would put PKT-21 \(new\) under AB#\d+' -and (& $abGet 's7b-new') -match 'would move H-1 AB#\d+ under PKT-21 \(new\) \(now under AB#\d+\)') 'a Parent packet this sync creates is (new) in its dry run' (& $abGet 's7b-new')
Assert-That ((& $abGet 's7-story') -match '^H-5>Small:Task\|' -and (& $abGet 's7-story') -match "note: H-5 names Parent PKT-05, but under AB#\d+ \(type User Story\) its Task can't go under a packet's Task, so that line has no effect here") 'under a story root the Parent line has no effect, and sync says so' (& $abGet 's7-story')
Assert-That ((& $abGet 'c-kept') -eq 'HOLD:session-a:renewed|HOLD:session-a:kept,HOLD:session-a:kept,HOLD:session-a:kept|posts=1|revs=0|writes=0|live=1') 'Azure claims: checks within the first third of the lease post nothing and add no revision, by the board''s clock three hours behind the local one' (& $abGet 'c-kept')
Assert-That ((& $abGet 'c-due') -eq 'HOLD:session-a:renewed|HOLD:session-a:kept|posts=2') 'Azure claims: once a third of the lease is gone the check renews, and the older claim comment stays' (& $abGet 'c-due')
Assert-That ((& $abGet 'c-competitor') -eq 'LOST:session-a|HOLD:session-a:kept|b-posts=0|a-posts=2') 'Azure claims: a competitor loses and its comment is deleted; an untrusted forged claim counts for nothing' (& $abGet 'c-competitor')
Assert-That ((& $abGet 'c-lapse') -eq 'HOLD:session-b:renewed|LOST:session-b|LOST:session-b|a-posts=2|b-posts=1') 'Azure claims: after the lease lapses a competitor takes over, and the old holder''s check and forced renewal return LOST' (& $abGet 'c-lapse')
Assert-That ((& $abGet 'c-race-due') -eq 'HOLD:session-b:renewed|LOST:session-b|holds=1|a-posts=2|b-posts=2') 'Azure claims: a competitor posting during a renewal loses; exactly one holder' (& $abGet 'c-race-due')
Assert-That ((& $abGet 'c-release') -eq '2|0|2|2|0') 'Azure claims: release deletes every claim comment of that session, and only those' (& $abGet 'c-release')
Assert-That ((& $abGet 'c-race-lapsed') -eq 'HOLD:session-x:renewed:lapsed|LOST:session-x|HOLD:session-y:renewed|LOST:session-y|x-posts=1|y-posts=1') 'Azure claims: two claims posted in one second inside each other''s checks: the lower comment id holds, the other loses; a renewal after a lapse says so' (& $abGet 'c-race-lapsed')
Assert-That ((& $abGet 'c-leftover') -eq 'HOLD:session-a:renewed,HOLD:session-a:renewed,HOLD:session-a:kept|LOST:session-a,LOST:session-a,HOLD:session-a:kept|deferred=session-b|a-posts=3|HOLD:session-a:renewed|HOLD:session-a:kept|LOST:session-a') 'Azure claims: a losing comment left behind never becomes a hold, even with -Force; the holder''s renewal defers (posting nothing that stays) and renews once it ages out' (& $abGet 'c-leftover')
Assert-That ((& $abGet 'c-leftover-late') -eq 'LOST:session-b|LOST:session-b') 'Azure claims: a deferred renewal with a minute or less left is LOST' (& $abGet 'c-leftover-late')
Assert-That ((& $abGet 'c-leftover-stall') -eq 'LOST:session-b') 'Azure claims: a renewal that stalls past the lease measures it again and doesn''t defer' (& $abGet 'c-leftover-stall')
Assert-That ((& $abGet 'c-late-view') -eq 'LOST:session-b|HOLD:session-b:renewed') 'Azure claims: a winning claim that shows up late is a LOST, never a deferral' (& $abGet 'c-late-view')
Assert-That ((& $abGet 'c-skew-ahead') -eq 'HOLD:session-s:renewed,HOLD:session-s:kept,HOLD:session-s:renewed|live=2') 'Azure claims: with the board''s clock five hours ahead, keep and renew still follow the board''s clock' (& $abGet 'c-skew-ahead')
Assert-That ((& $abGet 'setup') -match 'hierarchy: Epic > Feature > User Story > Task' -and (& $abGet 'setup') -match "'Task' has every mapped state \(New, Active, Closed\)" -and (& $abGet 'setup') -match "'User Story' has every mapped state \(New, Active, Resolved, Closed\)") 'setup checks the hierarchy''s types, the task type against taskStatusMap' (& $abGet 'setup')
Assert-That ((& $abGet 'setup-nomap') -match "MISSING states on 'Task': Resolved .*give the task type its own taskStatusMap") 'without taskStatusMap, setup names the missing task state and the fix' (& $abGet 'setup-nomap')
Assert-That ((& $abGet 'cfg-template') -eq 'ok' -and (& $abGet 'cfg-task-map') -match "taskStatusMap needs a state for 'Ready to merge'") 'the config refuses an incomplete taskStatusMap' "$(& $abGet 'cfg-template')`n$(& $abGet 'cfg-task-map')"
Assert-That ((& $abGet 'cfg-same-type') -eq 'ok' -and (& $abGet 's4-same-unrooted') -eq 'ok' -and (& $abGet 's4-same') -match 'needs a different work item type at each level \(.*got Epic, Feature, User Story, user story\)') 'one type at two levels is refused only where a plan names a root, so an older config keeps working' "$(& $abGet 'cfg-same-type')`n$(& $abGet 's4-same')`n$(& $abGet 's4-same-unrooted')"
Remove-Item -LiteralPath $abTest

Write-Host 'install'
$target = Join-Path ([System.IO.Path]::GetTempPath()) ("pw-install-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
New-Item -ItemType Directory -Path $target | Out-Null
try {
    & git -C $target init -q -b main
    & git -C $target remote add origin https://github.com/acme/widgets.git
    $installer = Join-Path $kit 'install.ps1'
    $r = Invoke-Kit $installer @('-Target', $target, '-WithInstructions')
    Assert-That ($r.Code -eq 0) 'install succeeds' $r.Text
    Assert-That ($r.Text -notmatch 'the kit lives in') 'installing into another repository gives no self-install warning' $r.Text
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
    Assert-That ((Get-Content -Raw (Join-Path $target '.github/agents/packet-dispatcher.agent.md')) -match '(?m)^disable-model-invocation: true\r?$') 'the dispatcher cannot be started as a subagent' ''
    $cfgPath = Join-Path $target '.github/packet-workflow.json'
    $cfgIn = Get-Content -Raw $cfgPath | ConvertFrom-Json -AsHashtable
    $cfgIn.models.light = @("Claude Sonnet 5.5 (Anthropic)", "it's fine")
    [System.IO.File]::WriteAllText($cfgPath, ($cfgIn | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    $r = Invoke-Kit $installer @('-Target', $target)
    $lightLine = (Get-Content (Join-Path $target '.github/agents/packet-reviewer-light.agent.md') | Where-Object { $_ -match '^model:' })
    Assert-That ($lightLine -eq "model: ['Claude Sonnet 5.5 (Anthropic)', 'it''s fine']" -and $r.Text -match 'update\s+\.github/agents/packet-reviewer-light\.agent\.md' -and $r.Text -notmatch 'update\s+\.github/agents/packet-reviewer-deep') 'models in the config rewrite only that class''s agents, quoted' $r.Text
    Assert-That ($r.Text -match '\d+ file\(s\) already up to date' -and $r.Text -match 'Agent models: .*light Claude Sonnet 5\.5 \(Anthropic\)') 'the installer reports unchanged files and the models it wrote' $r.Text
    $implementer = Join-Path $target '.github/agents/packet-implementer.agent.md'
    [System.IO.File]::WriteAllText($implementer, ((Get-Content -Raw $implementer) -replace '(?m)^model:.*$', "model: ['Hand Picked']"), [System.Text.UTF8Encoding]::new($false))
    $cfgIn.models.standard = @('Claude Sonnet 5.5 (Anthropic)')
    [System.IO.File]::WriteAllText($cfgPath, ($cfgIn | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    $r = Invoke-Kit $installer @('-Target', $target)
    Assert-That ($r.Text -match 'kept\s+\.github/agents/packet-implementer\.agent\.md' -and $r.Text -match 'except the kept packet-implementer, which keeps its own model: line' -and (Get-Content -Raw $implementer) -match "model: \['Hand Picked'\]") 'a hand-edited agent is kept, and the models summary says so' $r.Text
    # A file the kit dropped (as packet-reviewer-max was) goes when unchanged; changed locally, it stays and is named every time.
    $manifestFile = Join-Path $target '.github/packet-workflow.kit.json'
    $manifest = Get-Content -Raw $manifestFile | ConvertFrom-Json -AsHashtable
    $manifest.files['.github/agents/packet-reviewer-gone.agent.md'] = '0' * 64
    $manifest.files['.github/agents/packet-reviewer-dropped.agent.md'] = (Get-FileHash -Algorithm SHA256 (Join-Path $kit 'agents/packet-reviewer-deep.agent.md')).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText($manifestFile, ($manifest | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
    Set-Content -LiteralPath (Join-Path $target '.github/agents/packet-reviewer-gone.agent.md') -Value 'a project rule'
    Copy-Item -LiteralPath (Join-Path $kit 'agents/packet-reviewer-deep.agent.md') -Destination (Join-Path $target '.github/agents/packet-reviewer-dropped.agent.md')
    $r = Invoke-Kit $installer @('-Target', $target)
    Assert-That ($r.Text -match 'remove\s+\.github/agents/packet-reviewer-dropped\.agent\.md \(no longer in the kit\)' -and -not (Test-Path (Join-Path $target '.github/agents/packet-reviewer-dropped.agent.md'))) 'an unchanged file the kit dropped is removed' $r.Text
    Assert-That ($r.Text -match 'kept\s+\.github/agents/packet-reviewer-gone\.agent\.md \(no longer in the kit, but changed locally' -and (Test-Path (Join-Path $target '.github/agents/packet-reviewer-gone.agent.md'))) 'a changed file the kit dropped is kept and named' $r.Text
    $r = Invoke-Kit $installer @('-Target', $target)
    Assert-That ($r.Text -match 'kept\s+\.github/agents/packet-reviewer-gone\.agent\.md') 'it is named again on the next upgrade, until it is deleted' $r.Text
    Remove-Item -LiteralPath (Join-Path $target '.github/agents/packet-reviewer-gone.agent.md')
    $vendored = Join-Path $target 'packet-kit'
    New-Item -ItemType Directory -Path $vendored | Out-Null
    foreach ($item in 'install.ps1', 'VERSION', 'agents', 'skills', 'templates') { Copy-Item -Recurse -LiteralPath (Join-Path $kit $item) -Destination $vendored }
    $r = Invoke-Kit (Join-Path $vendored 'install.ps1') @('-Target', $target, '-DryRun')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'Installing into the repository the kit lives in') 'installing into the repository that holds the kit warns' $r.Text
}
finally { if (-not $Keep) { Remove-Item -Recurse -Force -LiteralPath $target } }

Write-Host ''
Write-Host "$($script:passes) passed, $($script:failures) failed"
if ($script:failures) { exit 1 }
