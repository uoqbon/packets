#!/usr/bin/env pwsh
#Requires -Version 7.2
<#
.SYNOPSIS
  progress.ps1: where a phase stands, from its packet files and the board.

.DESCRIPTION
  For each phase (or -Phase), reports:
    - status counts, and progress weighted by size (Done, and Done + Ready to merge);
    - progress by priority and by wave;
    - Ready packets with their verdicts (what can be dispatched now) and the blocked ones with reasons,
      a dependency in another repository (remotes) read from its issue there;
    - the owner's queue: Ready to merge, Needs human, and human tasks whose dependencies are done;
    - merge leverage: the unfinished packets whose completion would let the most Ready packets start;
    - the critical path through unfinished packets;
    - schedule risk: packets past their target, and Ready/Backlog packets due within two days;
    - stale items: In progress, In review or Needs human with no update for -StaleHours;
    - backlog problems: a packet waiting on lower-priority work (a priority inversion), or on a packet
      parked in Backlog behind the cut line (it can never start);
    - drift: packet files missing from the board, board items with no file, closed items not Done;
    - a health verdict: on track, at risk or off track, with the reasons;
    - with -Credits, an estimate of the AI credits each packet's runs cost (from its PR's trusted round
      markers and budget.creditsPerRun, docs/cost.md), the phase total and this month's against
      budget.monthlyCredits. It reads every packet PR's comments, so it is off by default.

  progress.ps1 [-Phase p] [-WorkingTree | -Ref <commit>] [-StaleHours 24] [-Today yyyy-MM-dd] [-Credits] [-Json]
  Exit codes: 0 report printed · 2 the report couldn't be made.
#>
param(
    [string]$Phase,
    [string]$Ref,
    [switch]$WorkingTree,
    [int]$StaleHours = 24,
    [string]$Today,
    [switch]$Json,
    [switch]$Credits,
    [string]$ConfigPath
)

. "$PSScriptRoot/../../packet-board/scripts/PacketWorkflow.ps1"

function Get-Weight($cfg, $p) {
    if ($p.Kind -eq 'human') { return 1 }
    if ($cfg.sizes.Contains([string]$p.Size)) { return [int]$cfg.sizes[[string]$p.Size] }
    2
}

function Format-Pct([double]$x) { '{0:0}%' -f (100 * $x) }

try {
    $cfg = Get-PwSharedConfig -Path $ConfigPath
    . "$PSScriptRoot/../../packet-board/scripts/providers/github-common.ps1"
    . "$PSScriptRoot/../../packet-board/scripts/providers/$($cfg.board.provider).ps1"
    Initialize-Prov -Config $cfg
    $src = if ($WorkingTree) { '' } elseif ($Ref) { $Ref } else {
        $main = "origin/$($cfg.defaultBranch)"
        & git rev-parse --verify -q "$main^{commit}" *> $null
        if ($LASTEXITCODE -eq 0) { $main } else { '' }
    }
    $asOf = if ($Today) { [DateTime]::ParseExact($Today, 'yyyy-MM-dd', $null) } else { [DateTime]::Today }
    $all = @(Get-PwPackets -Config $cfg -Ref $src)
    foreach ($bad in @($all | Where-Object { -not $_.Id })) { Write-Warning "$($bad.Path) has no packet ID; left out (validate-packets.ps1 says why)" }
    $all = @($all | Where-Object { $_.Id })
    $items = @(Get-ProvItems)
    $byId = @{}; foreach ($it in $items) { if (-not $byId.ContainsKey($it.Id)) { $byId[$it.Id] = $it } }
    $phases = @($all | Where-Object { -not $Phase -or $_.Phase -eq $Phase } | ForEach-Object Phase | Select-Object -Unique)
    if (-not $phases) { Stop-Pw "no packets$(if ($Phase) { " in phase $Phase" }) under $($cfg.paths.plans)" }
    # Dependencies in other repositories (remotes), read from their issues there. Every packet's, not only
    # unfinished ones': a closed packet whose status still says Ready is judged like any other.
    $remote = Get-PwRemoteItems -Config $cfg -Ids @($all | Where-Object { $phases -contains $_.Phase } | ForEach-Object { $_.DependsOn })
    foreach ($id in $remote.Keys) { $byId[$id] = $remote[$id] }
    $prCache = @{}
    $finder = { param($id) if (-not $prCache.ContainsKey($id)) { $prCache[$id] = Get-PwGhPrForPacket -Config $cfg -PacketId $id -State open }; $prCache[$id] }.GetNewClosure()
    if (-not $cfg.stacking) { $finder = { param($id) $null } }
    # -Credits: every packet PR once (pull requests always live on GitHub), then each one's round markers.
    $creditPrs = if ($Credits) { @(Invoke-PwGhJson pr list --repo $cfg.repo --state all --limit 1000 --json 'number,headRefName') } else { @() }

    $statusOf = { param($p) $it = $byId[$p.Id]; if ($it) { $it.Status } else { 'Not on board' } }
    $reports = foreach ($ph in $phases) {
        $info = Get-PwPhaseInfo -Config $cfg -Phase $ph -Ref $src
        $scope = @($all | Where-Object { $_.Phase -eq $ph })
        $agent = @($scope | Where-Object { $_.Kind -eq 'packet' })
        $human = @($scope | Where-Object { $_.Kind -eq 'human' })

        $counts = [ordered]@{}
        foreach ($s in @($script:Statuses) + 'Not on board') { $counts[$s] = 0 }
        foreach ($p in $agent) { $counts[(& $statusOf $p)]++ }
        $total = 0; $done = 0; $landed = 0
        foreach ($p in $agent) {
            $w = Get-Weight $cfg $p; $total += $w
            $s = & $statusOf $p
            if ($s -eq 'Done' -or (Test-PwItemDone $byId[$p.Id])) { $done += $w; $landed += $w }
            elseif ($s -eq 'Ready to merge') { $landed += $w }
        }
        $group = {
            param($key)
            foreach ($g in ($agent | Group-Object $key | Sort-Object { if ($_.Name -match '(\d+)') { [int]$Matches[1] } else { 999 } })) {
                $d = @($g.Group | Where-Object { Test-PwItemDone $byId[$_.Id] }).Count
                [pscustomobject]@{ Key = $(if ($g.Name) { $g.Name } else { '?' }); Done = $d; Total = $g.Count }
            }
        }
        $byPriority = @(& $group 'Priority')
        $byWave = @(& $group 'Wave')

        $verdicts = @{}
        foreach ($p in $agent) { $verdicts[$p.Id] = Get-PwVerdict -Packet $p -ItemsById $byId -Config $cfg -FindOpenPr $finder }
        $ready = @($agent | Where-Object { (& $statusOf $_) -eq 'Ready' } | Sort-Object { "$($_.Priority)-$($_.Wave)-$($_.Id)" })
        $startable = @($ready | Where-Object { $verdicts[$_.Id].Verdict -ne 'BLOCKED' } | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Verdict = $verdicts[$_.Id].Verdict; Priority = $_.Priority; Wave = $_.Wave; Title = $_.Title } })
        $blocked = @($ready | Where-Object { $verdicts[$_.Id].Verdict -eq 'BLOCKED' } | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Priority = $_.Priority; Reasons = $verdicts[$_.Id].Reasons } })

        $readyToMerge = @($agent | Where-Object { (& $statusOf $_) -eq 'Ready to merge' } | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Ref = $byId[$_.Id].Ref; UpdatedAt = $byId[$_.Id].UpdatedAt } } | Sort-Object UpdatedAt)
        $needsHuman = @($scope | Where-Object { (& $statusOf $_) -eq 'Needs human' } | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Ref = $byId[$_.Id].Ref; Title = $_.Title } })
        $humanNow = @($human | Where-Object { -not (Test-PwItemDone $byId[$_.Id]) -and -not ($_.DependsOn | Where-Object { -not (Test-PwItemDone $byId[$_]) }) } | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Target = $_.Target; Title = $_.Title } })

        # Merge leverage: finishing X lets these Ready packets start.
        $leverage = foreach ($x in ($scope | Where-Object { -not (Test-PwItemDone $byId[$_.Id]) })) {
            $freed = @($ready | Where-Object { $verdicts[$_.Id].Verdict -eq 'BLOCKED' -and $_.DependsOn -contains $x.Id } | Where-Object {
                    $p = $_
                    $copy = @{}; foreach ($k in $byId.Keys) { $copy[$k] = $byId[$k] }
                    $copy[$x.Id] = [pscustomobject]@{ Id = $x.Id; Status = 'Done'; Closed = $true; ClosedReason = 'completed'; Kind = $x.Kind }
                    (Get-PwVerdict -Packet $p -ItemsById $copy -Config $cfg -FindOpenPr $finder).Verdict -ne 'BLOCKED'
                } | ForEach-Object Id)
            $dependents = @($all | Where-Object { $_.DependsOn -contains $x.Id } | ForEach-Object Id)
            if ($freed.Count -or $dependents.Count -ge 2) {
                [pscustomobject]@{ Id = $x.Id; Status = (& $statusOf $x); Unblocks = $freed; Dependents = $dependents.Count }
            }
        }
        $leverage = @($leverage | Sort-Object @{ e = { $_.Unblocks.Count }; Descending = $true }, @{ e = { $_.Dependents }; Descending = $true }, Id | Select-Object -First 5)

        $crit = Get-PwCriticalPath -Packets $all -Config $cfg -Include { param($x) $x.Phase -eq $ph -and -not (Test-PwItemDone $byId[$x.Id]) }.GetNewClosure()

        $late = [System.Collections.Generic.List[object]]::new()
        $dueSoon = [System.Collections.Generic.List[object]]::new()
        foreach ($p in $scope) {
            $s = & $statusOf $p
            if (-not $p.Target -or $s -in 'Done', 'Ready to merge' -or (Test-PwItemDone $byId[$p.Id])) { continue }
            $t = [DateTime]::ParseExact($p.Target, 'yyyy-MM-dd', $null)
            $days = ($t - $asOf).Days
            if ($days -lt 0) { $late.Add([pscustomobject]@{ Id = $p.Id; Priority = $p.Priority; Status = $s; Target = $p.Target; DaysLate = - $days }) }
            elseif ($days -le 2 -and $s -in 'Backlog', 'Ready', 'Not on board') { $dueSoon.Add([pscustomobject]@{ Id = $p.Id; Priority = $p.Priority; Status = $s; Target = $p.Target; DaysLeft = $days }) }
        }

        $stale = @(foreach ($p in $scope) {
                $it = $byId[$p.Id]
                if (-not $it -or $it.Status -notin 'In progress', 'In review', 'Needs human' -or -not $it.UpdatedAt) { continue }
                $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]$it.UpdatedAt).TotalHours
                if ($age -ge $StaleHours) { [pscustomobject]@{ Id = $p.Id; Status = $it.Status; Hours = [int]$age } }
            })

        # Backlog problems: a packet waiting on a lower-priority one, or on one parked behind the cut line.
        $prioNum = { param($x) if ($x.Priority -match '^P(\d)$') { [int]$Matches[1] } else { 9 } }
        $inversions = [System.Collections.Generic.List[object]]::new()
        $parked = [System.Collections.Generic.List[object]]::new()
        $pkById = @{}; foreach ($x in $all) { $pkById[$x.Id] = $x }
        foreach ($p in $scope) {
            if (Test-PwItemDone $byId[$p.Id]) { continue }
            foreach ($d in $p.DependsOn) {
                $dp = $pkById[$d]
                if (-not $dp -or (Test-PwItemDone $byId[$d])) { continue }
                if ((& $prioNum $dp) -gt (& $prioNum $p)) { $inversions.Add([pscustomobject]@{ Id = $p.Id; Priority = $p.Priority; DependsOn = $d; DependencyPriority = $dp.Priority }) }
                if ((& $statusOf $dp) -eq 'Backlog' -and (& $statusOf $p) -ne 'Backlog') { $parked.Add([pscustomobject]@{ Id = $p.Id; Status = (& $statusOf $p); DependsOn = $d }) }
            }
        }

        $drift = [System.Collections.Generic.List[string]]::new()
        foreach ($p in $scope) {
            $it = $byId[$p.Id]
            if (-not $it) { $drift.Add("$($p.Id) has a packet file but no board item (board.ps1 sync)"); continue }
            if ($it.Closed -and $it.ClosedReason -ne 'not_planned' -and $it.Status -ne 'Done') { $drift.Add("$($p.Id) is closed but shows $($it.Status) (board.ps1 reconcile)") }
            if (-not $it.Closed -and $it.Status -eq 'Done') { $drift.Add("$($p.Id) shows Done but is still open") }
        }

        $reasons = [System.Collections.Generic.List[string]]::new()
        $health = 'on track'
        $p0Late = @($late | Where-Object { $_.Priority -eq 'P0' })
        $p0Human = @($needsHuman | Where-Object { $id = $_.Id; ($scope | Where-Object { $_.Id -eq $id }).Priority -eq 'P0' })
        if ($p0Late.Count) { $health = 'off track'; $reasons.Add("P0 past target: $(($p0Late | ForEach-Object { "$($_.Id) ($($_.DaysLate)d)" }) -join ', ')") }
        if ($p0Human.Count) { $health = 'off track'; $reasons.Add("P0 waiting on the owner: $(($p0Human | ForEach-Object Id) -join ', ')") }
        if ($health -ne 'off track') {
            if ($late.Count) { $health = 'at risk'; $reasons.Add("past target: $(($late | ForEach-Object Id) -join ', ')") }
            $p0Soon = @($dueSoon | Where-Object { $_.Priority -eq 'P0' })
            if ($p0Soon.Count) { $health = 'at risk'; $reasons.Add("P0 due within 2 days and not started: $(($p0Soon | ForEach-Object Id) -join ', ')") }
            if ($stale.Count) { $health = 'at risk'; $reasons.Add("stale: $(($stale | ForEach-Object { "$($_.Id) $($_.Status) $($_.Hours)h" }) -join ', ')") }
            if ($inversions | Where-Object { $_.Priority -eq 'P0' }) { $health = 'at risk'; $reasons.Add("P0 waits on lower-priority work: $(($inversions | Where-Object { $_.Priority -eq 'P0' } | ForEach-Object { "$($_.Id) -> $($_.DependsOn) ($($_.DependencyPriority))" }) -join ', ')") }
            if ($parked.Count) { $health = 'at risk'; $reasons.Add("waiting on Backlog packets: $(($parked | ForEach-Object { "$($_.Id) -> $($_.DependsOn)" }) -join ', ')") }
            if ($agent.Count -and -not $startable.Count -and -not @($agent | Where-Object { (& $statusOf $_) -in 'In progress', 'In review' }).Count -and $done -lt $total) { $health = 'at risk'; $reasons.Add('nothing is in flight and nothing Ready can start') }
        }
        if (-not $reasons.Count) { $reasons.Add('no late, stale or blocked P0 work') }

        $creditReport = $null
        if ($Credits) {
            $withRounds = @(foreach ($p in $agent) {
                    $prefix = "pkt/$($p.Id.ToLowerInvariant())-"
                    $pr = @($creditPrs | Where-Object { "$($_.headRefName)".StartsWith($prefix) } | Sort-Object { [int]$_.number } -Descending) | Select-Object -First 1
                    if (-not $pr) { continue }
                    [pscustomobject]@{ Id = $p.Id; Size = $p.Size; Pr = [int]$pr.number; Rounds = (Get-PwGhRounds -Config $cfg -Pr ([string]$pr.number)) }
                })
            # The pool resets on the 1st, UTC: "this month" is the UTC month unless -Today names a day.
            $creditReport = Get-PwCreditSummary -Config $cfg -Packets $withRounds -Today $(if ($Today) { $asOf } else { [DateTime]::UtcNow })
        }

        $report = [pscustomobject]@{
            Phase = $ph; Title = $info.Title; Source = $(if ($src) { $src } else { 'working tree' }); Today = $asOf.ToString('yyyy-MM-dd')
            Health = $health; HealthReasons = @($reasons)
            Totals = [pscustomobject]@{ Packets = $agent.Count; HumanTasks = $human.Count; Weight = $total; DoneWeight = $done; LandedWeight = $landed; DonePercent = if ($total) { [math]::Round(100 * $done / $total) } else { 0 }; LandedPercent = if ($total) { [math]::Round(100 * $landed / $total) } else { 0 } }
            Counts = $counts; ByPriority = $byPriority; ByWave = $byWave
            Startable = $startable; Blocked = $blocked
            OwnerQueue = [pscustomobject]@{ ReadyToMerge = $readyToMerge; NeedsHuman = $needsHuman; HumanTasksNow = $humanNow }
            Leverage = $leverage
            CriticalPath = [pscustomobject]@{ Weight = $crit.Weight; Path = $crit.Path }
            Late = @($late); DueSoon = @($dueSoon); Stale = $stale; Drift = @($drift)
            Inversions = @($inversions); WaitingOnBacklog = @($parked)
        }
        if ($Credits) { $report | Add-Member -NotePropertyName Credits -NotePropertyValue $creditReport }
        $report
    }
    $reports = @($reports)
    if ($Json) { if ($reports.Count -eq 1) { $reports[0] | ConvertTo-Json -Depth 8 } else { $reports | ConvertTo-Json -Depth 8 } ; exit 0 }

    foreach ($r in $reports) {
        Write-Output "== $($r.Title) [$($r.Phase)] · $($r.Today) · $($r.Health.ToUpperInvariant())"
        foreach ($why in $r.HealthReasons) { Write-Output "   - $why" }
        Write-Output ("Progress: {0}% done, {1}% done or ready to merge (by size; {2} packets, {3} human tasks)" -f $r.Totals.DonePercent, $r.Totals.LandedPercent, $r.Totals.Packets, $r.Totals.HumanTasks)
        Write-Output ('Status:   ' + (($r.Counts.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ' · '))
        Write-Output ('Priority: ' + (($r.ByPriority | ForEach-Object { "$($_.Key) $($_.Done)/$($_.Total)" }) -join ' · '))
        Write-Output ('Waves:    ' + (($r.ByWave | ForEach-Object { "$($_.Key) $($_.Done)/$($_.Total)" }) -join ' · '))
        Write-Output ''
        Write-Output 'Can start now:'
        if ($r.Startable) { foreach ($s in $r.Startable) { Write-Output ("  {0,-7} {1,-8} {2} {3} {4}" -f $s.Verdict, $s.Id, $s.Priority, $s.Wave, $s.Title) } } else { Write-Output '  nothing' }
        if ($r.Blocked) { Write-Output 'Ready but blocked:'; foreach ($b in $r.Blocked) { Write-Output "  $($b.Id) ($($b.Priority)): $($b.Reasons -join '; ')" } }
        Write-Output 'Owner queue:'
        if ($r.OwnerQueue.ReadyToMerge) { Write-Output "  merge:   $(($r.OwnerQueue.ReadyToMerge | ForEach-Object Id) -join ', ')" }
        if ($r.OwnerQueue.NeedsHuman) { Write-Output "  decide:  $(($r.OwnerQueue.NeedsHuman | ForEach-Object { "$($_.Id) ($($_.Title))" }) -join ', ')" }
        if ($r.OwnerQueue.HumanTasksNow) { Write-Output "  do:      $(($r.OwnerQueue.HumanTasksNow | ForEach-Object { "$($_.Id) $($_.Title)$(if ($_.Target) { " by $($_.Target)" })" }) -join ', ')" }
        if (-not ($r.OwnerQueue.ReadyToMerge -or $r.OwnerQueue.NeedsHuman -or $r.OwnerQueue.HumanTasksNow)) { Write-Output '  empty' }
        if ($r.Leverage) {
            Write-Output 'Merge leverage (finish these first):'
            foreach ($l in $r.Leverage) { Write-Output ("  {0,-8} {1,-15} unblocks {2}{3}" -f $l.Id, $l.Status, $(if ($l.Unblocks) { $l.Unblocks -join ', ' } else { 'nothing Ready yet' }), "; $($l.Dependents) dependents in all") }
        }
        Write-Output "Critical path left (weight $($r.CriticalPath.Weight)): $(if ($r.CriticalPath.Path) { $r.CriticalPath.Path -join ' -> ' } else { 'none' })"
        if ($r.Late) { Write-Output "Late: $(($r.Late | ForEach-Object { "$($_.Id) $($_.Status) $($_.DaysLate)d" }) -join ', ')" }
        if ($r.DueSoon) { Write-Output "Due soon, not started: $(($r.DueSoon | ForEach-Object { "$($_.Id) by $($_.Target)" }) -join ', ')" }
        if ($r.Stale) { Write-Output "Stale (> $StaleHours h): $(($r.Stale | ForEach-Object { "$($_.Id) $($_.Status) $($_.Hours)h" }) -join ', ')" }
        if ($r.Inversions) { Write-Output "Priority inversions: $(($r.Inversions | ForEach-Object { "$($_.Id) ($($_.Priority)) waits on $($_.DependsOn) ($($_.DependencyPriority))" }) -join ', ')" }
        if ($r.WaitingOnBacklog) { Write-Output "Waiting on Backlog: $(($r.WaitingOnBacklog | ForEach-Object { "$($_.Id) ($($_.Status)) waits on $($_.DependsOn)" }) -join ', ')" }
        if ($r.Drift) { Write-Output 'Drift:'; foreach ($d in $r.Drift) { Write-Output "  $d" } }
        if ($r.PSObject.Properties['Credits']) {
            $c = $r.Credits
            Write-Output 'Credits (an estimate from round markers and budget.creditsPerRun; calibrate it as the kit''s docs/cost.md says):'
            foreach ($x in $c.Packets) { Write-Output ('  {0,-8} {1}  PR #{2,-5} {3} round(s), {4} reviewer run(s), {5} implementer run(s)  {6,7:N0}{7}' -f $x.Id, $x.Size, $x.Pr, $x.Rounds, $x.ReviewerRuns, $x.ImplementerRuns, $x.Credits, $(if ($x.Finished) { '' } else { '  (in review)' })) }
            if (-not $c.Packets) { Write-Output '  no packet PR has a round report yet' }
            $monthText = if ($c.MonthlyCredits) { ' of {0:N0} ({1:N0} left; about {2} more packet(s) at that rate)' -f $c.MonthlyCredits, $c.Left, $(if ($null -ne $c.PacketsLeft) { $c.PacketsLeft } else { '?' }) } else { ' (set budget.monthlyCredits to compare)' }
            Write-Output ('  phase {0:N0} · {1:N0} per finished packet · {2}: {3:N0}{4}' -f $c.Total, $c.PerFinishedPacket, $c.Month, $c.ThisMonth, $monthText)
        }
        Write-Output ''
    }
}
catch [PwError] {
    [Console]::Error.WriteLine("progress: $($_.Exception.Message)")
    exit 2
}
catch {
    [Console]::Error.WriteLine("progress: $($_.Exception.Message)")
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    exit 2
}
