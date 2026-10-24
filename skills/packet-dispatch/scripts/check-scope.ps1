#!/usr/bin/env pwsh
#Requires -Version 7.2
<#
.SYNOPSIS
  check-scope.ps1: does a packet branch stay inside the paths its packet owns?

.DESCRIPTION
  Compares every path the branch changed (both sides of a rename) with the packet: its Owns (minus !
  exclusions), its shared touchpoints and its decision record.

  The comparison base is the brief's base (-Base), until the branch merges the default branch: from then
  on it is the default-branch commit the branch last merged: the merge base of HEAD and the default
  branch's tip as origin reports it (git ls-remote, never the local origin/* refs, which a shell in this
  clone can move). Files
  another packet landed on the default branch come in with that merge, so they aren't this packet's
  changes; an edit to one of them, or a revert, still is. The packet and the config are read at the same
  base: a commit on the default branch, so the branch can't add locks or paths in its own favour, and an
  amendment the owner merged there counts.

  OUTSIDE    a path the packet neither owns nor lists as a touchpoint            (fails)
  LOCKED     a path under a lock (config locks) the packet doesn't hold          (fails)
  MACHINERY  the kit, its config, agents, skills, hooks, prompts or workflows, not owned (fails)
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

$machineryRe = '(^|/)\.github/(workflows|actions|agents|skills|prompts|instructions|copilot|hooks)/|(^|/)\.github/copilot-instructions\.md$|(^|/)AGENTS\.md$|(^|/)\.github/packet-workflow\.json$|(^|/)\.claude/|(^|/)\.agents/|(^|/)\.github/packet-lenses/'

function Get-RemoteDefaultTip([string]$Root) {
    <# The default branch's tip as origin reports it now (git ls-remote), fetched when it isn't here yet.
       Never the local origin/* refs: anything with a shell in this clone can move those, and a moved ref
       would pick the comparison base and the packet text this check reads. $null without an origin, or
       when origin can't be reached. #>
    if (@(& git -C $Root remote 2>$null) -notcontains 'origin') { return $null }
    $lines = @(& git -C $Root ls-remote --symref origin HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("check-scope: couldn't read origin's default branch; comparing against the brief's base"); return $null }
    $branch = $null; $tip = $null
    foreach ($l in $lines) {
        $m = [regex]::Match($l, '^ref: refs/heads/(?<b>\S+)\s+HEAD$'); if ($m.Success) { $branch = $m.Groups['b'].Value }
        $m = [regex]::Match($l, '^(?<s>[0-9a-f]{40}(?:[0-9a-f]{24})?)\s+HEAD$'); if ($m.Success) { $tip = $m.Groups['s'].Value }
    }
    if (-not $branch -or -not $tip) { [Console]::Error.WriteLine("check-scope: origin reports no default branch; comparing against the brief's base"); return $null }
    & git -C $Root cat-file -e "$tip^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { & git -C $Root fetch -q origin "refs/heads/$branch" 2>$null; & git -C $Root cat-file -e "$tip^{commit}" 2>$null }
    if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("check-scope: couldn't fetch origin's $branch; comparing against the brief's base"); return $null }
    $tip
}

try {
    $root = Get-RepoRoot
    $briefSha = (Invoke-PwGit -C $root merge-base $Base $Head | Select-Object -First 1).Trim()
    # After the branch merges the default branch, compare against the default-branch commit it merged, not
    # the brief's base: otherwise every file another packet landed meanwhile counts as this packet's change.
    # The saved base stays when the default branch is behind it (a stacked packet whose dependency hasn't
    # merged yet), and when there's no origin or it can't be reached: then merged-in files show as OUTSIDE,
    # which is a false alarm, never a hidden change.
    $baseSha = $briefSha
    $mainTip = Get-RemoteDefaultTip $root
    if ($mainTip) {
        $mainSha = (Invoke-PwGit -C $root merge-base $mainTip $Head | Select-Object -First 1).Trim()
        & git -C $root merge-base --is-ancestor $mainSha $briefSha 2>$null
        if ($LASTEXITCODE -ne 0) { $baseSha = $mainSha }
    }
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
        [pscustomobject]@{ Packet = $pk.Id; Base = $baseSha; BriefBase = $briefSha; Changed = @($paths); Results = @($results); Ok = ($failing.Count -eq 0) } | ConvertTo-Json -Depth 5
    }
    else {
        Write-Output "$($pk.Id): $($paths.Count) changed path(s) against $($baseSha.Substring(0, 7))$(if ($baseSha -ne $briefSha) { " (the default branch as last merged into this branch; brief base $($briefSha.Substring(0, 7)))" })"
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
