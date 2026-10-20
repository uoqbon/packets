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

  Each agent's model: line comes from the config's models map (strong: the dispatcher and the deep and max
  reviewers; standard: the implementer and the standard reviewer; light: the light reviewer). To use other
  model names (your own API key, an organization's model list), edit models in .github/packet-workflow.json
  and run the installer again.

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
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Get-Sha([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function Get-TextSha([string]$Text) { [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($utf8.GetBytes($Text))).ToLowerInvariant() }
function Write-Step([string]$Verb, [string]$Path) { Write-Output ('{0,-10} {1}' -f $Verb, $Path) }

$Target = (Resolve-Path -LiteralPath $Target).Path
$top = & git -C $Target rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -ne 0) { throw "$Target is not inside a git repository" }
$Target = ($top | Select-Object -First 1).Trim()
$kitTop = & git -C $kit rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -eq 0 -and $Target -eq ($kitTop | Select-Object -First 1).Trim()) {
    Write-Warning 'Installing into the repository the kit lives in: the installed copies under .github/agents and .github/skills will sit next to the kit source.'
}

$manifestPath = Join-Path $Target '.github/packet-workflow.kit.json'
$old = @{}
if (Test-Path -LiteralPath $manifestPath) {
    $m = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -AsHashtable
    foreach ($k in $m.files.Keys) { $old[$k] = $m.files[$k] }
}

# The target's config, or a new one from the template. It's read before the agents are written,
# because their model: lines come from its models map.
$configPath = Join-Path $Target '.github/packet-workflow.json'
$configIsNew = -not (Test-Path -LiteralPath $configPath)
$template = Get-Content -Raw (Join-Path $kit 'templates/packet-workflow.json') | ConvertFrom-Json -AsHashtable
if ($configIsNew) {
    $cfg = Get-Content -Raw (Join-Path $kit 'templates/packet-workflow.json') | ConvertFrom-Json -AsHashtable
    $url = & git -C $Target remote get-url origin 2>$null
    if ($LASTEXITCODE -eq 0 -and $url -match 'github\.com[:/](?<o>[^/]+)/(?<r>[^/]+?)(\.git)?$') { $cfg.repo = "$($Matches.o)/$($Matches.r)" }
    $head = & git -C $Target symbolic-ref --short refs/remotes/origin/HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $head) {
        $cfg.defaultBranch = ($head | Select-Object -First 1).Trim() -replace '^origin/', ''
        $cfg.guardrails.protectedBranches = @($cfg.defaultBranch)
    }
}
else {
    try { $cfg = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json -AsHashtable }
    catch { throw ".github/packet-workflow.json is not valid JSON: $($_.Exception.Message)" }
}
$hasModels = $cfg['models'] -is [System.Collections.IDictionary]
$models = @{}
foreach ($class in 'strong', 'standard', 'light') {
    $list = if ($hasModels -and $cfg.models.Contains($class)) { $cfg.models[$class] } else { $template.models[$class] }
    $list = @(@($list) | Where-Object { $_ -is [string] -and $_.Trim() } | ForEach-Object { $_.Trim() })
    if (-not $list.Count) { throw "models.$class in .github/packet-workflow.json must name at least one model" }
    $models[$class] = $list
}
$agentModelClass = @{
    'packet-dispatcher.agent.md'        = 'strong'
    'packet-reviewer-deep.agent.md'     = 'strong'
    'packet-reviewer-max.agent.md'      = 'strong'
    'packet-implementer.agent.md'       = 'standard'
    'packet-reviewer-standard.agent.md' = 'standard'
    'packet-reviewer-light.agent.md'    = 'light'
}

$plan = [System.Collections.Generic.List[object]]::new()
foreach ($f in Get-ChildItem -LiteralPath (Join-Path $kit 'agents') -File -Filter '*.agent.md') {
    $plan.Add(@{ Source = $f.FullName; Dest = ".github/agents/$($f.Name)"; ModelClass = $agentModelClass[$f.Name] })
}
foreach ($f in Get-ChildItem -LiteralPath (Join-Path $kit 'skills') -File -Recurse) {
    $rel = [System.IO.Path]::GetRelativePath((Join-Path $kit 'skills'), $f.FullName).Replace('\', '/')
    $plan.Add(@{ Source = $f.FullName; Dest = ".github/skills/$rel"; ModelClass = $null })
}

$installed = [ordered]@{}
$kept = [System.Collections.Generic.List[string]]::new()
$unchanged = 0
$keptAgents = [System.Collections.Generic.List[string]]::new()
foreach ($item in $plan) {
    $dest = Join-Path $Target $item.Dest
    # An agent is written with its class's models; every other file is copied as it is.
    $content = $null
    if ($item.ModelClass) {
        $modelLine = 'model: [' + (($models[$item.ModelClass] | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', ') + ']'
        $content = ([regex]'(?m)^model:[^\r\n]*').Replace([System.IO.File]::ReadAllText($item.Source), [System.Text.RegularExpressions.MatchEvaluator] { param($m) $modelLine }, 1)
        $newSha = Get-TextSha $content
    }
    else { $newSha = Get-Sha $item.Source }
    if (Test-Path -LiteralPath $dest) {
        $curSha = Get-Sha $dest
        if ($curSha -eq $newSha) { $installed[$item.Dest] = $newSha; $unchanged++; continue }
        $untouched = $old.ContainsKey($item.Dest) -and $old[$item.Dest] -eq $curSha
        if (-not $untouched -and -not $Force) {
            $kept.Add($item.Dest)
            if ($item.ModelClass) { $keptAgents.Add(([System.IO.Path]::GetFileName($item.Dest) -replace '\.agent\.md$', '')) }
            if ($old.ContainsKey($item.Dest)) { $installed[$item.Dest] = $old[$item.Dest] }
            Write-Step 'kept' "$($item.Dest) (changed locally; -Force replaces it)"
            continue
        }
        Write-Step 'update' $item.Dest
    }
    else { Write-Step 'add' $item.Dest }
    if (-not $DryRun) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        if ($null -ne $content) { [System.IO.File]::WriteAllText($dest, $content, $utf8) }
        else { Copy-Item -LiteralPath $item.Source -Destination $dest -Force }
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

if ($configIsNew) {
    Write-Step 'add' ".github/packet-workflow.json (repo $($cfg.repo), default branch $($cfg.defaultBranch); review the board settings)"
    if (-not $DryRun) { [System.IO.File]::WriteAllText($configPath, ($cfg | ConvertTo-Json -Depth 10) + "`n", $utf8) }
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
if ($unchanged) { Write-Output "$unchanged file(s) already up to date." }
if ($kept.Count) { Write-Output "$($kept.Count) locally changed file(s) kept; compare them with the kit, or rerun with -Force." }
Write-Output "Agent models: strong $($models.strong -join ' > '); standard $($models.standard -join ' > '); light $($models.light -join ' > ')$(if (-not $configIsNew -and -not $hasModels) { ' (the kit''s defaults: add a models map to .github/packet-workflow.json to change them)' })$(if ($keptAgents.Count) { "; except the kept $($keptAgents -join ', '), which keep$(if ($keptAgents.Count -eq 1) { 's its own model: line (-Force rewrites it)' } else { ' their own model: lines (-Force rewrites them)' })" })."
Write-Output @'
Next:
  1. Review .github/packet-workflow.json (board provider, prefixes, commands, guardrails, locks).
  2. pwsh -File .github/skills/packet-board/scripts/board.ps1 setup -DryRun
  3. Commit .github/agents, .github/skills, .github/packet-workflow*.json in a pull request.
  4. In Copilot Chat: /packet-plan <your plan>, then /packet-board sync, then the packet-dispatcher agent.
'@
