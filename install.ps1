#!/usr/bin/env pwsh
#Requires -Version 7.2
<#
.SYNOPSIS
  install.ps1: install or upgrade the packet workflow kit in a repository.

.DESCRIPTION
  Copies the kit into the target repository where GitHub Copilot finds it:
    agents/*.agent.md  -> <target>/.github/agents/
    skills/<name>/     -> <target>/.github/skills/<name>/
  and, when they don't exist yet:
    templates/packet-workflow.json -> <target>/.github/packet-workflow.json  (repo and default branch filled in)

  It records what it installed, with hashes, in <target>/.github/packet-workflow.kit.json. On an upgrade a
  file is replaced only if it is unchanged since the last install; a file you edited is left alone and
  listed, unless -Force. Project-specific review lenses belong in .github/packet-lenses/, which the kit
  never touches.

  -WithInstructions also adds (or refreshes) the workflow's rules in .github/copilot-instructions.md,
  between <!-- packet-workflow:start --> and <!-- packet-workflow:end -->.

  pwsh -File install.ps1 -Target <repo root> [-DryRun] [-Force] [-WithInstructions]
#>
param(
    [Parameter(Mandatory)][string]$Target,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$WithInstructions
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$kit = $PSScriptRoot
$version = (Get-Content -Raw (Join-Path $kit 'VERSION')).Trim()

function Get-Sha([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function Write-Step([string]$Verb, [string]$Path) { Write-Output ('{0,-10} {1}' -f $Verb, $Path) }

$Target = (Resolve-Path -LiteralPath $Target).Path
$top = & git -C $Target rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0) { throw "$Target is not inside a git repository" }
$Target = ($top | Select-Object -First 1).Trim()
if ([System.IO.Path]::GetFullPath($Target) -eq [System.IO.Path]::GetFullPath((Join-Path $kit '../..'))) {
    Write-Warning 'Installing into the repository the kit lives in: the installed copies under .github/agents and .github/skills will sit next to the kit source.'
}

$manifestPath = Join-Path $Target '.github/packet-workflow.kit.json'
$old = @{}
if (Test-Path -LiteralPath $manifestPath) {
    $m = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -AsHashtable
    foreach ($k in $m.files.Keys) { $old[$k] = $m.files[$k] }
}

$plan = [System.Collections.Generic.List[object]]::new()
foreach ($f in Get-ChildItem -LiteralPath (Join-Path $kit 'agents') -File -Filter '*.agent.md') {
    $plan.Add(@{ Source = $f.FullName; Dest = ".github/agents/$($f.Name)" })
}
foreach ($f in Get-ChildItem -LiteralPath (Join-Path $kit 'skills') -File -Recurse) {
    $rel = [System.IO.Path]::GetRelativePath((Join-Path $kit 'skills'), $f.FullName).Replace('\', '/')
    $plan.Add(@{ Source = $f.FullName; Dest = ".github/skills/$rel" })
}

$installed = [ordered]@{}
$kept = [System.Collections.Generic.List[string]]::new()
foreach ($item in $plan) {
    $dest = Join-Path $Target $item.Dest
    $newSha = Get-Sha $item.Source
    if (Test-Path -LiteralPath $dest) {
        $curSha = Get-Sha $dest
        if ($curSha -eq $newSha) { $installed[$item.Dest] = $newSha; continue }
        $untouched = $old.ContainsKey($item.Dest) -and $old[$item.Dest] -eq $curSha
        if (-not $untouched -and -not $Force) {
            $kept.Add($item.Dest)
            if ($old.ContainsKey($item.Dest)) { $installed[$item.Dest] = $old[$item.Dest] }
            Write-Step 'kept' "$($item.Dest) (changed locally; -Force replaces it)"
            continue
        }
        Write-Step 'update' $item.Dest
    }
    else { Write-Step 'add' $item.Dest }
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        Copy-Item -LiteralPath $item.Source -Destination $dest -Force
    }
    $installed[$item.Dest] = $newSha
}
foreach ($gone in ($old.Keys | Where-Object { -not $installed.Contains($_) -and -not ($plan | Where-Object Dest -eq $_) })) {
    $dest = Join-Path $Target $gone
    if ((Test-Path -LiteralPath $dest) -and (Get-Sha $dest) -eq $old[$gone]) {
        Write-Step 'remove' "$gone (no longer in the kit)"
        if (-not $DryRun) { Remove-Item -LiteralPath $dest }
    }
}

$configPath = Join-Path $Target '.github/packet-workflow.json'
if (-not (Test-Path -LiteralPath $configPath)) {
    $cfg = Get-Content -Raw (Join-Path $kit 'templates/packet-workflow.json') | ConvertFrom-Json -AsHashtable
    $url = & git -C $Target remote get-url origin 2>$null
    if ($LASTEXITCODE -eq 0 -and $url -match 'github\.com[:/](?<o>[^/]+)/(?<r>[^/]+?)(\.git)?$') { $cfg.repo = "$($Matches.o)/$($Matches.r)" }
    $head = & git -C $Target symbolic-ref --short refs/remotes/origin/HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $head) {
        $cfg.defaultBranch = ($head | Select-Object -First 1).Trim() -replace '^origin/', ''
        $cfg.guardrails.protectedBranches = @($cfg.defaultBranch)
    }
    Write-Step 'add' ".github/packet-workflow.json (repo $($cfg.repo), default branch $($cfg.defaultBranch); review the board settings)"
    if (-not $DryRun) { [System.IO.File]::WriteAllText($configPath, ($cfg | ConvertTo-Json -Depth 10) + "`n", [System.Text.UTF8Encoding]::new($false)) }
}

if ($WithInstructions) {
    $instrPath = Join-Path $Target '.github/copilot-instructions.md'
    $snippet = (Get-Content -Raw (Join-Path $kit 'templates/copilot-instructions.md')).Trim()
    $text = if (Test-Path -LiteralPath $instrPath) { Get-Content -Raw -LiteralPath $instrPath } else { '' }
    $pattern = '(?s)<!-- packet-workflow:start -->.*?<!-- packet-workflow:end -->'
    $new = if ($text -match $pattern) { [regex]::Replace($text, $pattern, { param($m) $snippet }) } else { ($text.TrimEnd() + "`n`n" + $snippet).TrimStart() + "`n" }
    if ($new -ne $text) {
        Write-Step $(if ($text) { 'update' } else { 'add' }) '.github/copilot-instructions.md (packet workflow rules)'
        if (-not $DryRun) { [System.IO.File]::WriteAllText($instrPath, $new, [System.Text.UTF8Encoding]::new($false)) }
    }
}

if (-not $DryRun) {
    $manifest = [ordered]@{ kit = 'packet-workflow'; version = $version; installedAt = [DateTime]::UtcNow.ToString('o'); files = $installed }
    [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5) + "`n", [System.Text.UTF8Encoding]::new($false))
}

Write-Output ''
Write-Output "packet workflow kit $version $(if ($DryRun) { 'would be installed' } else { 'installed' }) in $Target"
if ($kept.Count) { Write-Output "$($kept.Count) locally changed file(s) kept; compare them with the kit, or rerun with -Force." }
Write-Output @'
Next:
  1. Review .github/packet-workflow.json (board provider, prefixes, commands, guardrails, locks).
  2. pwsh -File .github/skills/packet-board/scripts/board.ps1 setup -DryRun
  3. Commit .github/agents, .github/skills, .github/packet-workflow*.json in a pull request.
  4. In Copilot Chat: /packet-plan <your plan>, then /packet-board sync, then the packet-dispatcher agent.
'@
