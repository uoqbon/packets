#!/usr/bin/env pwsh
#Requires -Version 7.2
<#
.SYNOPSIS
  validate-packets.ps1: check a phase's packet files before they reach the board.

.DESCRIPTION
  Reads every packet file under <plans>/<phase>/packets/ (all phases, so cross-phase dependencies
  resolve) and reports, for the phase asked for:

  A dependency whose ID prefix the config's remotes lists is another repository's packet: it needs no
  file here and isn't looked up (board.ps1 deps does that); the summary lists it.

  ERROR  a malformed packet; a duplicate ID; a dependency that doesn't exist; a cycle; two packets that
         can run at the same time (neither depends on the other) and own the same existing file; two
         such packets that hold the same lock; a packet that owns a lock's paths without declaring it.
  WARN   globs of two concurrent packets that may overlap on files not yet written; a shared touchpoint
         one concurrent packet owns outright; a touchpoint missing from the plan's touchpoint table;
         a packet scheduled in a wave no later than one of its dependencies; an unknown lens; a packet
         big enough that it should probably be split.

  Then it prints the shape of the plan: packets per priority, size and wave, the widest wave, the
  packets most others depend on (land those first) and the critical path.

  validate-packets.ps1 [-Phase <dir>] [-Ref <commit>] [-Json]
  Exit codes: 0 no errors · 1 errors found · 2 the check couldn't run.
#>
param(
    [string]$Phase,
    [string]$Ref,
    [switch]$Json,
    [string]$ConfigPath
)

. "$PSScriptRoot/../../packet-board/scripts/PacketWorkflow.ps1"

try {
    $cfg = Get-PwConfig -Path $ConfigPath
    $all = @(Get-PwPackets -Config $cfg -Ref $Ref)
    $scope = @($all | Where-Object { -not $Phase -or $_.Phase -eq $Phase })
    if ($scope.Count -eq 0) { Stop-Pw "no packet files under $($cfg.paths.plans)/$(if ($Phase) { $Phase } else { '<phase>' })/packets/" }
    $findings = [System.Collections.Generic.List[object]]::new()
    function Add-Finding([string]$Level, [string]$Id, [string]$Text) { $findings.Add([pscustomobject]@{ Level = $Level; Id = $Id; Text = $Text }) }

    $byId = @{}
    foreach ($p in @($all | Where-Object { -not $_.Id -and $scope -contains $_ })) {
        foreach ($problem in (Test-PwPacket -Packet $p -Config $cfg)) { Add-Finding 'ERROR' $p.Path $problem }
    }
    $all = @($all | Where-Object { $_.Id })
    $scope = @($scope | Where-Object { $_.Id })
    foreach ($p in $all) {
        if ($byId.ContainsKey($p.Id)) { Add-Finding 'ERROR' $p.Id "duplicate ID: $($byId[$p.Id].Path) and $($p.Path)"; continue }
        $byId[$p.Id] = $p
    }
    $inScope = [System.Collections.Generic.HashSet[string]]::new([string[]]@($scope | Where-Object Id | ForEach-Object Id))
    $remoteDeps = [System.Collections.Generic.List[object]]::new()

    # 1. Each packet on its own.
    foreach ($p in $scope) {
        foreach ($problem in (Test-PwPacket -Packet $p -Config $cfg)) { Add-Finding 'ERROR' $(if ($p.Id) { $p.Id } else { $p.Path }) $problem }
        foreach ($d in $p.DependsOn) {
            $remoteRepo = Get-PwRemoteRepo -Config $cfg -Id $d
            if ($remoteRepo) { $remoteDeps.Add([pscustomobject]@{ Id = $d; Repo = $remoteRepo; By = $p.Id }); continue }
            if ($byId.ContainsKey($d)) { continue }
            $prefix = ($d -split '-')[0]
            $hint = if ($prefix -ne $cfg.packetPrefix -and $prefix -ne $cfg.humanPrefix) { " (a packet in another repository needs its prefix $prefix in the config's remotes)" } else { '' }
            Add-Finding 'ERROR' $p.Id "depends on $d, which has no packet file$hint"
        }
        if ($p.Kind -eq 'packet') {
            if ($p.Acceptance.Count -gt 8) { Add-Finding 'WARN' $p.Id "$($p.Acceptance.Count) acceptance criteria: one PR that big rarely clears review in three rounds; consider splitting" }
            if ($p.Owns.Count -gt 12) { Add-Finding 'WARN' $p.Id "owns $($p.Owns.Count) globs; a packet that wide is hard to keep apart from its neighbours" }
            if ($p.ReviewTier -eq '4') { Add-Finding 'WARN' $p.Id "Review tier 4 is from before tiers 3 and 4 merged; review-scope reads it as 3, the top tier: write 3" }
            if ($p.Size -eq 'L' -and $p.Lenses.Count -gt 5) { Add-Finding 'WARN' $p.Id "size L with $($p.Lenses.Count) lenses: expect a tier-3 review; consider splitting" }
        }
    }

    # 2. The graph.
    $packets = @($byId.Values)
    foreach ($c in (Get-PwCycles $packets)) { Add-Finding 'ERROR' (($c -split ' -> ')[0]) "dependency cycle: $c" }
    $anc = Get-PwAncestors $packets
    $concurrent = {
        param($a, $b)
        -not ($anc[$a.Id].Contains($b.Id) -or $anc[$b.Id].Contains($a.Id))
    }

    # 3. Ownership, touchpoints and locks between packets that can run at the same time.
    $tracked = @(Invoke-PwGit -C $cfg.repoRoot ls-files)
    if ($Ref) { $tracked = @(Invoke-PwGit -C $cfg.repoRoot ls-tree -r --name-only $Ref) }
    $agentPackets = @($packets | Where-Object { $_.Kind -eq 'packet' } | Sort-Object Id)
    $ownedFiles = @{}
    foreach ($p in $agentPackets) {
        $ownedFiles[$p.Id] = [System.Collections.Generic.HashSet[string]]::new([string[]]@($tracked | Where-Object { Test-PwPacketOwnsPath -Packet $p -Path $_ -OwnsOnly }))
    }
    $lockPaths = @{}; foreach ($l in @($cfg.locks)) { $lockPaths[$l.name] = @($l.paths) }

    for ($i = 0; $i -lt $agentPackets.Count; $i++) {
        $a = $agentPackets[$i]
        for ($j = $i + 1; $j -lt $agentPackets.Count; $j++) {
            $b = $agentPackets[$j]
            if (-not ($inScope.Contains($a.Id) -or $inScope.Contains($b.Id))) { continue }
            if (-not (& $concurrent $a $b)) { continue }
            $both = @($ownedFiles[$a.Id] | Where-Object { $ownedFiles[$b.Id].Contains($_) })
            if ($both.Count) {
                Add-Finding 'ERROR' "$($a.Id),$($b.Id)" "$($a.Id) and $($b.Id) can run at the same time and both own $($both.Count) existing file(s), e.g. $($both[0]). Split the paths or make one depend on the other."
            }
            else {
                foreach ($ga in $a.Owns) {
                    foreach ($gb in $b.Owns) {
                        $pa = Get-PwGlobPrefix $ga; $pb = Get-PwGlobPrefix $gb
                        $overlap = ($pa.StartsWith($pb) -or $pb.StartsWith($pa))
                        if (-not $overlap) { continue }
                        $longer = if ($pa.Length -ge $pb.Length) { $pa } else { $pb }
                        # An exclusion clears the overlap only when it is a whole directory (dir/** or a plain
                        # path) that contains the other glob's area; '!**/*.md' excludes files, not an area.
                        # The other glob's area: a plain path is itself (a file or a whole directory); a glob
                        # with wildcards lives in the directory its literal prefix ends in ('src/Api*.cs' lives
                        # in 'src/', not 'src/Api/'). The exclusion must contain all of that area.
                        $carves = {
                            param($ex, $otherGlob)
                            $e = (ConvertTo-PwRepoPath $ex)
                            $d = if ($e -match '^(?<d>[^*?]+)/\*\*$') { $Matches.d } elseif ($e -notmatch '[*?]') { $e } else { $null }
                            $o = ConvertTo-PwRepoPath $otherGlob
                            $area = if ($o -notmatch '[*?]') { "$o/" } else {
                                $prefix = Get-PwGlobPrefix $o
                                $slash = $prefix.LastIndexOf('/')
                                if ($slash -ge 0) { $prefix.Substring(0, $slash + 1) } else { '' }
                            }
                            $d -and $area.StartsWith("$d/")
                        }
                        $excludedByA = $a.Excludes | Where-Object { & $carves $_ $gb }
                        $excludedByB = $b.Excludes | Where-Object { & $carves $_ $ga }
                        if ($excludedByA -or $excludedByB) { continue }
                        # Certain: the same glob, or one glob inside the other's whole directory (dir/** or a plain dir).
                        $na = $ga.Trim().TrimEnd('/'); $nb = $gb.Trim().TrimEnd('/')
                        $dirA = if ($na -match '^(?<d>[^*?]+)/\*\*$') { $Matches.d } elseif ($na -notmatch '[*?]') { $na } else { $null }
                        $dirB = if ($nb -match '^(?<d>[^*?]+)/\*\*$') { $Matches.d } elseif ($nb -notmatch '[*?]') { $nb } else { $null }
                        $certain = ($na -eq $nb) -or ($dirA -and ($pb + '/').StartsWith("$dirA/")) -or ($dirB -and ($pa + '/').StartsWith("$dirB/"))
                        if ($certain) {
                            Add-Finding 'ERROR' "$($a.Id),$($b.Id)" "$($a.Id) owns '$ga' and $($b.Id) owns '$gb', and they can run at the same time: both own whatever is written there. Split the paths, add a '!' exclusion, or order them."
                            continue
                        }
                        Add-Finding 'WARN' "$($a.Id),$($b.Id)" "$($a.Id) owns '$ga' and $($b.Id) owns '$gb', and they can run at the same time: the globs may meet on files not yet written. Narrow one, add a '!' exclusion, or order them."
                    }
                }
            }
            foreach ($pair in @(@($a, $b), @($b, $a))) {
                $owner = $pair[0]; $toucher = $pair[1]
                foreach ($t in $toucher.Touchpoints) {
                    if (Test-PwPacketOwnsPath -Packet $owner -Path $t.Path -OwnsOnly) {
                        Add-Finding 'WARN' $toucher.Id "touchpoint $($t.Path) is owned by $($owner.Id), which can run at the same time; make $($toucher.Id) depend on $($owner.Id), or move the file to the plan's shared touchpoints"
                    }
                }
            }
            $sharedLocks = @($a.Locks | Where-Object { $b.Locks -contains $_ })
            foreach ($l in $sharedLocks) { Add-Finding 'ERROR' "$($a.Id),$($b.Id)" "$($a.Id) and $($b.Id) both hold lock '$l' and can run at the same time; order them with Depends on" }
        }
    }
    foreach ($p in ($agentPackets | Where-Object { $inScope.Contains($_.Id) })) {
        foreach ($name in $lockPaths.Keys) {
            if ($p.Locks -contains $name) { continue }
            $hit = $p.Owns | Where-Object {
                $g = $_
                @($lockPaths[$name] | Where-Object { $lp = Get-PwGlobPrefix $_; $gp = Get-PwGlobPrefix $g; ($gp.StartsWith($lp) -and $lp) -or (Test-PwGlob $g @($_)) }).Count -gt 0
            }
            $files = @($ownedFiles[$p.Id] | Where-Object { Test-PwGlob $_ $lockPaths[$name] })
            if ($hit -or $files.Count) { Add-Finding 'ERROR' $p.Id "owns paths under lock '$name' ($(@($hit + $files | Select-Object -First 1)[0])) but doesn't list it under Locks" }
        }
    }

    # 4. Touchpoints against the plan's table, and waves against dependencies.
    $phaseNames = @($scope | ForEach-Object Phase | Select-Object -Unique)
    foreach ($ph in $phaseNames) {
        $info = Get-PwPhaseInfo -Config $cfg -Phase $ph -Ref $Ref
        if (-not $info.Exists) { Add-Finding 'WARN' $ph "no $($info.Path): the plan is the index of its packets"; continue }
        if (@($info.Roots).Count -gt 1) { Add-Finding 'ERROR' $ph "$($info.Path) names more than one root item ($((@($info.Roots) | ForEach-Object { "$($_.Line) $($_.Ref)" }) -join ', ')): the board builds one tree per phase, so keep one **Epic:**, **Feature:** or **User Story:** line" }
        $planText = if ($Ref) { (Invoke-PwGit show "${Ref}:$($info.Path)") -join "`n" } else { Get-Content -Raw -LiteralPath (Join-Path $cfg.repoRoot $info.Path) }
        $allowed = $null
        $m = [regex]::Match($planText, '(?ms)^##+\s+[^\n]*[Tt]ouchpoint[^\n]*\n(?<body>.*?)(?=^##\s|\z)')
        if ($m.Success) { $allowed = @([regex]::Matches($m.Groups['body'].Value, '`(?<p>[^`]+)`') | ForEach-Object { $_.Groups['p'].Value }) }
        elseif ($scope | Where-Object { $_.Phase -eq $ph -and $_.Touchpoints.Count }) {
            Add-Finding 'WARN' $ph "packets use shared touchpoints but $($info.Path) has no '## Shared touchpoints' section, so they go unchecked"
        }
        foreach ($p in ($scope | Where-Object { $_.Phase -eq $ph })) {
            if ($planText -notmatch [regex]::Escape($p.Id)) { Add-Finding 'WARN' $p.Id "the plan $($info.Path) doesn't mention $($p.Id)" }
            if ($null -ne $allowed) {
                foreach ($t in $p.Touchpoints) {
                    if (-not ($allowed | Where-Object { $_ -eq $t.Path -or (Test-PwGlob $t.Path @($_)) })) { Add-Finding 'WARN' $p.Id "touchpoint $($t.Path) isn't in the plan's shared touchpoints table" }
                }
            }
        }
    }
    foreach ($p in $scope) {
        foreach ($d in $p.DependsOn) {
            $dp = $byId[$d]
            if ($dp -and $p.Priority -match '^P(\d)$') {
                $mine = [int]$Matches[1]
                if ($dp.Priority -match '^P(\d)$' -and [int]$Matches[1] -gt $mine) { Add-Finding 'WARN' $p.Id "$($p.Priority) depends on $d ($($dp.Priority)): raise $d or drop the dependency" }
            }
            if ($dp -and $dp.InitialStatus -eq 'Backlog' -and $p.InitialStatus -ne 'Backlog') { Add-Finding 'WARN' $p.Id "starts Ready but depends on $d, which starts in Backlog: it can't start until $d is promoted" }
        }
    }
    foreach ($p in $scope) {
        if ($p.Wave -notmatch '(\d+)') { continue }
        $w = [int]$Matches[1]
        foreach ($d in $p.DependsOn) {
            $dp = $byId[$d]
            if ($dp -and $dp.Kind -eq 'packet' -and $dp.Wave -match '(\d+)' -and [int]$Matches[1] -ge $w) {
                Add-Finding 'WARN' $p.Id "wave $($p.Wave) is not after its dependency $d (wave $($dp.Wave))"
            }
        }
    }
    $knownLenses = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $lensDir = Join-Path $PSScriptRoot '../../packet-review/lenses'
    $projectLensDir = Join-Path $cfg.repoRoot $cfg.paths.lenses
    foreach ($dir in @($lensDir, $projectLensDir)) {
        if ($dir -and (Test-Path -LiteralPath $dir)) { foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.md')) { [void]$knownLenses.Add($f.BaseName) } }
    }
    foreach ($k in @($cfg.review.lensPaths.Keys)) { [void]$knownLenses.Add($k) }
    foreach ($p in $scope) { foreach ($l in $p.Lenses) { if ($knownLenses.Count -and -not $knownLenses.Contains($l)) { Add-Finding 'WARN' $p.Id "unknown review lens '$l' (no lenses/$l.md in the kit or $($cfg.paths.lenses))" } } }

    # 5. The shape of the plan.
    $agentScope = @($scope | Where-Object { $_.Kind -eq 'packet' })
    $dependents = @{}
    foreach ($p in $packets) { foreach ($d in $p.DependsOn) { $dependents[$d] = 1 + [int]$dependents[$d] } }
    $hubs = @($agentScope | Where-Object { [int]$dependents[$_.Id] -ge 3 } | Sort-Object { - [int]$dependents[$_.Id] } | ForEach-Object { "$($_.Id) ($([int]$dependents[$_.Id]) dependents)" })
    $waves = $agentScope | Group-Object { if ($_.Wave) { $_.Wave } else { '?' } } | Sort-Object { if ($_.Name -match '(\d+)') { [int]$Matches[1] } else { 999 } }
    $crit = Get-PwCriticalPath -Packets $packets -Config $cfg -Include { param($x) $inScope.Contains($x.Id) }.GetNewClosure()
    $byPriority = [ordered]@{}; foreach ($g in ($agentScope | Group-Object Priority | Sort-Object Name)) { $byPriority[[string]$g.Name] = $g.Count }
    $bySize = [ordered]@{}; foreach ($g in ($agentScope | Group-Object Size | Sort-Object { $cfg.sizes[[string]$_.Name] })) { $bySize[[string]$g.Name] = $g.Count }
    $summary = [pscustomobject]@{
        Phase        = if ($Phase) { $Phase } else { ($phaseNames -join ', ') }
        Packets      = $agentScope.Count
        HumanTasks   = @($scope | Where-Object { $_.Kind -eq 'human' }).Count
        ByPriority   = $byPriority
        BySize       = $bySize
        Waves        = @($waves | ForEach-Object { [pscustomobject]@{ Wave = $_.Name; Count = $_.Count; Packets = @($_.Group | ForEach-Object Id) } })
        Hubs         = $hubs
        CriticalPath = [pscustomobject]@{ Weight = $crit.Weight; Path = $crit.Path }
        Remote       = @($remoteDeps | Group-Object Id | Sort-Object { ($_.Name -split '-')[0] }, { [int]($_.Name -split '-')[1] } | ForEach-Object { [pscustomobject]@{ Id = $_.Name; Repo = $_.Group[0].Repo; DependedOnBy = @($_.Group | ForEach-Object By) } })
        Errors       = @($findings | Where-Object Level -eq 'ERROR').Count
        Warnings     = @($findings | Where-Object Level -eq 'WARN').Count
    }

    if ($Json) {
        [pscustomobject]@{ Summary = $summary; Findings = @($findings) } | ConvertTo-Json -Depth 8
    }
    else {
        foreach ($f in ($findings | Sort-Object Level, Id)) { Write-Output ('{0,-5} {1,-8} {2}' -f $f.Level, $f.Id, $f.Text) }
        if ($findings.Count) { Write-Output '' }
        Write-Output "phase $($summary.Phase): $($summary.Packets) packets, $($summary.HumanTasks) human tasks"
        Write-Output ("  priority: " + (($summary.ByPriority.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', '))
        Write-Output ("  size:     " + (($summary.BySize.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', '))
        foreach ($w in $summary.Waves) { Write-Output ("  wave {0,-4} {1,2}: {2}" -f $w.Wave, $w.Count, ($w.Packets -join ', ')) }
        if ($hubs) { Write-Output "  land first (most dependents): $($hubs -join ', ')" }
        Write-Output "  critical path (weight $($crit.Weight)): $($crit.Path -join ' -> ')"
        if ($summary.Remote) { Write-Output "  in other repositories: $(($summary.Remote | ForEach-Object { "$($_.Id) in $($_.Repo) (for $($_.DependedOnBy -join ', '))" }) -join ', ')" }
        Write-Output "  $($summary.Errors) error(s), $($summary.Warnings) warning(s)"
    }
    if ($summary.Errors -gt 0) { exit 1 }
}
catch [PwError] {
    [Console]::Error.WriteLine("validate-packets: $($_.Exception.Message)")
    exit 2
}
catch {
    [Console]::Error.WriteLine("validate-packets: $($_.Exception.Message)")
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    exit 2
}
