#!/usr/bin/env pwsh
#Requires -Version 7.2
<#
.SYNOPSIS
  check-scope.ps1: does a packet branch stay inside the paths its packet owns?

.DESCRIPTION
  Compares every path the branch changed (<Base>...<Head>, both sides of a rename) with the packet as it
  was at the base: its Owns (minus ! exclusions), its shared touchpoints and its decision record.

  OUTSIDE    a path the packet neither owns nor lists as a touchpoint            (fails)
  LOCKED     a path under a lock (config locks) the packet doesn't hold          (fails)
  MACHINERY  the kit, its config, agents, skills, prompts or workflows, not owned (fails)
  TOUCH      a shared touchpoint, with the edit the packet allows; more than 10 changed lines warns
  DIRTY      uncommitted or untracked changes in the worktree: commit or discard them first (fails)

  check-scope.ps1 -Packet <ID> -Base <ref> [-Head HEAD] [-Json]
  Exit codes: 0 inside its paths · 1 something outside · 2 the check couldn't run.
#>
param(
    [Parameter(Mandatory)][string]$Packet,
    [Parameter(Mandatory)][string]$Base,
    [string]$Head = 'HEAD',
    [switch]$Json,
    [string]$ConfigPath
)

. "$PSScriptRoot/../../packet-board/scripts/PacketWorkflow.ps1"

$machineryRe = '(^|/)\.github/(workflows|actions|agents|skills|prompts|instructions|copilot)/|(^|/)\.github/copilot-instructions\.md$|(^|/)AGENTS\.md$|(^|/)\.github/packet-workflow\.json$|(^|/)\.claude/|(^|/)\.agents/|(^|/)\.github/packet-lenses/'

try {
    $root = Get-RepoRoot
    $baseSha = (Invoke-PwGit -C $root merge-base $Base $Head | Select-Object -First 1).Trim()
    # The config as it is at the base, so a branch can't add locks or paths in its own favour.
    $cfg = Get-PwConfig -Path $ConfigPath -Ref $(if ($ConfigPath) { '' } else { $baseSha })
    # The project's lens directory (paths.lenses) is review machinery wherever it is configured.
    $lensDir = ConvertTo-PwRepoPath $cfg.paths.lenses
    if ($lensDir) { $machineryRe += '|^' + [regex]::Escape($lensDir) + '/' }
    $pk = @(Get-PwPackets -Config $cfg -Ref $baseSha) | Where-Object { $_.Id -eq $Packet.ToUpperInvariant() } | Select-Object -First 1
    if (-not $pk) { Stop-Pw "no packet file for $Packet at the base $($baseSha.Substring(0, 7))" }
    $decision = $cfg.paths.decisions.Replace('{phase}', $pk.Phase).Replace('{packet}', $pk.Id)

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(Invoke-PwGit -C $root diff --name-status --find-renames --no-color "$baseSha...$Head" | Where-Object { $_ })) {
        $parts = $line -split "`t"
        foreach ($p in ($parts | Select-Object -Skip 1)) { if ($p -and -not $paths.Contains($p)) { $paths.Add($p) } }
    }
    $numstat = @{}
    foreach ($line in @(Invoke-PwGit -C $root diff --numstat --no-renames "$baseSha...$Head" | Where-Object { $_ })) {
        $parts = $line -split "`t", 3
        if ($parts.Count -eq 3 -and $parts[0] -ne '-') { $numstat[$parts[2]] = [int]$parts[0] + [int]$parts[1] }
    }
    $held = @(foreach ($l in $pk.Locks) { (@($cfg.locks) | Where-Object { $_.name -eq $l }).paths })
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $paths) {
        $owned = $p -eq $decision -or (Test-PwPacketOwnsPath -Packet $pk -Path $p -OwnsOnly)
        $touch = $pk.Touchpoints | Where-Object { Test-PwGlob $p @($_.Path) } | Select-Object -First 1
        foreach ($lock in @($cfg.locks)) {
            if ((Test-PwGlob $p @($lock.paths)) -and -not (Test-PwGlob $p $held)) { $results.Add([pscustomobject]@{ Kind = 'LOCKED'; Path = $p; Detail = "lock '$($lock.name)' isn't held by $($pk.Id)" }) }
        }
        if (-not $owned -and -not $touch -and [regex]::IsMatch($p, $machineryRe)) { $results.Add([pscustomobject]@{ Kind = 'MACHINERY'; Path = $p; Detail = 'the workflow kit, its config or the agent setup; revert it (the kit must run as it was at the base)' }); continue }
        if ($owned) { continue }
        if ($touch) {
            $n = if ($numstat.ContainsKey($p)) { $numstat[$p] } else { 0 }
            $results.Add([pscustomobject]@{ Kind = 'TOUCH'; Path = $p; Detail = "$n changed lines; allowed: $(if ($touch.Rule) { $touch.Rule } else { 'a small additive edit' })$(if ($n -gt 10) { ' -- WARNING: more than a small edit' })" })
            continue
        }
        $results.Add([pscustomobject]@{ Kind = 'OUTSIDE'; Path = $p; Detail = "not in $($pk.Id)'s Owns or shared touchpoints" })
    }
    $dirty = @(Invoke-PwGit -C $root status --porcelain | Where-Object { $_ })
    foreach ($d in $dirty) { $results.Add([pscustomobject]@{ Kind = 'DIRTY'; Path = $d.Substring(3); Detail = "uncommitted ($($d.Substring(0, 2).Trim()))" }) }

    $failing = @($results | Where-Object { $_.Kind -in 'OUTSIDE', 'LOCKED', 'MACHINERY', 'DIRTY' })
    if ($Json) {
        [pscustomobject]@{ Packet = $pk.Id; Base = $baseSha; Changed = @($paths); Results = @($results); Ok = ($failing.Count -eq 0) } | ConvertTo-Json -Depth 5
    }
    else {
        Write-Output "$($pk.Id): $($paths.Count) changed path(s) against $($baseSha.Substring(0, 7))"
        foreach ($r in $results) { Write-Output ('{0,-9} {1}  ({2})' -f $r.Kind, $r.Path, $r.Detail) }
        Write-Output $(if ($failing.Count) { "FAIL: $($failing.Count) path(s) outside the packet. Revert them, or stop and ask the owner to re-scope." } else { 'OK: inside the packet''s paths' })
    }
    if ($failing.Count) { exit 1 }
}
catch [PwError] {
    [Console]::Error.WriteLine("check-scope: $($_.Exception.Message)")
    exit 2
}
catch {
    [Console]::Error.WriteLine("check-scope: $($_.Exception.Message)")
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    exit 2
}
