# cost-doc.tests.ps1 (PKT-7, extended by PKT-8): docs/cost.md's figures against the estimator on the
# default rates, the default creditsPerRun in the template, the defaults and the page, Get-PwCreditSummary's
# rule for a finished packet, the solo profile's section, and the README's rows for the solo-budget keys. Run by tests/run-tests.ps1 in a child scope: plain variables only, never a script-scope
# one, and kit code only through Invoke-CaseProbe (never dot-sourced here).

$costPage = Get-Content -LiteralPath (Join-Path $kit 'docs/cost.md')
$costText = $costPage -join "`n"
$num = { param([string]$s) $t = ($s -replace '[*,\s]', ''); if ($t -match '^\d+(\.\d+)?$') { [double]$t } else { 0.0 } }
# The table rows that follow a line, up to the first line that isn't a table row, as lists of cells.
$tableAfter = {
    param([string]$Lead)
    $at = [Array]::FindIndex([string[]]$costPage, [Predicate[string]] { param($l) $l.StartsWith($Lead) })
    if ($at -lt 0) { return , @() }
    $rows = [System.Collections.Generic.List[object]]::new()
    $i = $at + 1
    while ($i -lt $costPage.Count -and -not $costPage[$i].StartsWith('|')) { $i++ }
    for (; $i -lt $costPage.Count -and $costPage[$i].StartsWith('|'); $i++) {
        $cells = @($costPage[$i].Trim().Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
        if ($cells[0] -notmatch '^-+$') { $rows.Add($cells) }
    }
    , @($rows | Select-Object -Skip 1)
}

Write-Host '  the default rates'
# Keys sorted at every level, so the three sources compare as text.
$sortedJson = 'function Sort-Deep($v) { if ($v -is [System.Collections.IDictionary]) { $o = [ordered]@{}; foreach ($k in @($v.Keys | Sort-Object)) { $o[$k] = Sort-Deep $v[$k] }; $o } elseif ($v -is [System.Collections.IList] -and $v -isnot [string]) { , @($v | ForEach-Object { Sort-Deep $_ }) } else { $v } }'
$templatePath = (Join-Path $kit 'templates/packet-workflow.json').Replace("'", "''")
# The JSON under "Recommended budget profile", not the first block on the page.
$jsonBlock = if ($costText -match '(?s)## Recommended budget profile.*?```json\s*(\{.*?\})\s*```') { $Matches[1] } else { '{}' }
$jsonPath = Join-Path ([System.IO.Path]::GetTempPath()) "pw-costdoc-$([guid]::NewGuid().ToString('n').Substring(0, 8)).json"
[System.IO.File]::WriteAllText($jsonPath, $jsonBlock, [System.Text.UTF8Encoding]::new($false))
try {
    $p = Invoke-CaseProbe @"
$sortedJson
'want=' + (Sort-Deep @{
        dispatcher = 25; dispatcherPerRound = @{ S = 150; M = 165; L = 195 }; dispatcherPerReviewerRun = 18
        implementer = @{ S = 105; M = 200; L = 355 }; implementerFix = @{ S = 40; M = 55; L = 75 }
        reviewerByTier = @{ S = @(20, 50, 98); M = @(30, 70, 140); L = @(40, 95, 190) }; laterRoundFactor = 0.85 } | ConvertTo-Json -Depth 5 -Compress)
'defaults=' + (Sort-Deep `$script:Defaults.budget.creditsPerRun | ConvertTo-Json -Depth 5 -Compress)
'template=' + (Sort-Deep (Get-Content -Raw '$templatePath' | ConvertFrom-Json -AsHashtable).budget.creditsPerRun | ConvertTo-Json -Depth 5 -Compress)
'page=' + (Sort-Deep (Get-Content -Raw '$($jsonPath.Replace("'", "''"))' | ConvertFrom-Json -AsHashtable).budget.creditsPerRun | ConvertTo-Json -Depth 5 -Compress)
"@
} finally { Remove-Item -LiteralPath $jsonPath -ErrorAction SilentlyContinue }
$want = if ($p.Text -match '(?m)^want=(.*)$') { $Matches[1].Trim() } else { 'none' }
foreach ($source in 'defaults', 'template', 'page') {
    $got = if ($p.Text -match "(?m)^$source=(.*)$") { $Matches[1].Trim() } else { '' }
    Assert-That ($p.Code -eq 0 -and $got -eq $want) "budget.creditsPerRun in the $source is GPT-6.1 Sol's: dispatcher 25, per round 150/165/195, per reviewer run 18, tier 3 98/140/190" "$($p.Text)"
}

Write-Host '  docs/cost.md against the estimator'
$perPacket = & $tableAfter 'Credits per packet under the defaults'
Assert-That ($perPacket.Count -eq 8) 'cost.md has the eight rows of "Credits per packet under the defaults"' ($perPacket | ForEach-Object { $_ -join ' | ' } | Out-String)
# Each row as round markers: its tiers and lenses per round, a fix after every round but the last.
$cases = @(foreach ($row in $perPacket) {
        $tiers = @(if ($row[1] -match '\(([\d,\s]+)\)') { $Matches[1] -split ',\s*' | ForEach-Object { [int]$_ } })
        $lenses = @($row[2] -split ',\s*' | ForEach-Object { [int]$_ })
        $size = if ($row[0] -match '^(S|M|L),') { $Matches[1] } else { 'S' }   # stage 5's PKT-1 was an S packet
        [pscustomobject]@{ Name = $row[0]; Size = $size; Tiers = $tiers; Lenses = $lenses; Resume = (& $num $row[8]); Total = (& $num $row[9]); Parts = (& $num $row[5]) + (& $num $row[6]) + (& $num $row[7]) + (& $num $row[8]) }
    })
$body = '$ec = Merge-PwHashtable $script:Defaults @{}' + "`n"
foreach ($c in $cases) {
    $rounds = for ($i = 0; $i -lt $c.Tiers.Count; $i++) {
        $names = (1..$c.Lenses[$i] | ForEach-Object { "lens$_" }) -join ','
        "@{ Kind = 'round'; Round = $($i + 1); Tier = '$($c.Tiers[$i])'; Lenses = '$names'; Outcome = '$(if ($i -lt $c.Tiers.Count - 1) { 'fix' } else { 'pass' })' }"
    }
    $body += "'$($c.Name)=' + (Get-PwCreditEstimate -Config `$ec -Size '$($c.Size)' -Rounds @($($rounds -join ', '))).Credits`n"
}
$p = Invoke-CaseProbe $body
foreach ($c in $cases) {
    $est = if ($p.Text -match "(?m)^$([regex]::Escape($c.Name))=(\d+)") { [double]$Matches[1] + $c.Resume } else { -1 }
    $limit = if ($c.Name -match 'best case') { 0.10 } else { 0.01 }
    $ok = $c.Tiers.Count -ge 1 -and $c.Tiers.Count -eq $c.Lenses.Count -and $c.Total -gt 0 -and [Math]::Abs($est - $c.Total) -le $limit * $c.Total
    Assert-That $ok "cost.md's $($c.Name) ($($c.Total)) is within $($limit * 100)% of Get-PwCreditEstimate on the default rates, plus the resume share it states ($est)" $p.Text
    Assert-That ([Math]::Abs($c.Parts - $c.Total) -le 5) "cost.md's $($c.Name) row adds up: its parts make $($c.Parts), its total $($c.Total)" ''
}
$typical = @{}
foreach ($c in $cases) { if ($c.Name -match '^(S|M|L), typical') { $typical[$Matches[1]] = $c.Total } }
Assert-That ($typical['S'] -and [Math]::Abs($typical['S'] - 1180) -le 15 -and [Math]::Abs($typical['M'] - 2160) -le 15 -and [Math]::Abs($typical['L'] - 3430) -le 15) 'the typical packets are the planned three-tier figures: S about 1,180, M about 2,160, L about 3,430' "S $($typical['S']), M $($typical['M']), L $($typical['L'])"

Write-Host '  the phase'
$phase = & $tableAfter 'A phase of N packets'
Assert-That ($phase.Count -eq 3) 'cost.md has the three rows of the phase table (5, 10 and 20 packets)' ($phase | ForEach-Object { $_ -join ' | ' } | Out-String)
$mixes = @{ '5' = @(2, 2, 1); '10' = @(3, 5, 2); '20' = @(6, 10, 4) }
$plan = @{ '5' = 200; '10' = 275; '20' = 450 }
foreach ($row in $phase) {
    $n = if ($row[0] -match '^(\d+) packets') { $Matches[1] } else { '?' }
    $m = $mixes[$n]
    $packets = $m[0] * $typical['S'] + $m[1] * $typical['M'] + $m[2] * $typical['L']
    $over = $plan[$n] + 75
    $ok = $m -and [Math]::Abs((& $num $row[1]) - $packets) -le 50 -and (& $num $row[2]) -eq $over -and [Math]::Abs((& $num $row[3]) - ($packets + $over)) -le 50 -and [Math]::Abs((& $num $row[4]) - ($packets + $over) / 12500) -le 0.05
    Assert-That $ok "the $n-packet phase follows from the typical packets, packet-plan ($($plan[$n])) and four board or progress sessions (75)" ($row -join ' | ')
}
$ten = @($phase | Where-Object { $_[0] -match '^10 packets' }) | Select-Object -First 1
$tenTotal = if ($ten) { & $num $ten[3] } else { 0 }
Assert-That ($tenTotal -gt 0 -and $costText -match "about $([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:N0}', $tenTotal / 10)) credits \(US\`$$([Math]::Round($tenTotal / 1000, [MidpointRounding]::AwayFromZero))\)" -and $costText -match "about $([Math]::Round(12500 / ($tenTotal / 10), 1)) packets") 'per packet all in is the 10-packet phase over ten, and the packets a month follow from it' "10-packet phase $tenTotal"
Assert-That ($tenTotal -ge 21000 -and $tenTotal -le 22000 -and $costText -match '`packet-plan` about 200 \(5 packets\), 275 \(10\)') 'about 2,160 a packet all in, with packet-plan at about 275 for 10 packets' "10-packet phase $tenTotal"

$inShort = if ($costText -match '(?s)\*\*In short\.\*\*(.*?)\n## ') { $Matches[1] } else { '' }
$fmt = { param($v) [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:N0}', $v) }
$headline = $typical.Count -eq 3 -and $inShort -match "about $(& $fmt $typical['S']) credits \(S\), $(& $fmt $typical['M']) \(M\) or $(& $fmt $typical['L']) \(L\)" -and
    $inShort -match "about $(& $fmt ($tenTotal / 10)) credits a packet" -and $inShort -match "\($([Math]::Round(12500 / ($tenTotal / 10), 1))\)" -and $inShort -match "every $([Math]::Round($tenTotal / 12500, 1)) months"
Assert-That $headline 'the "In short" figures are the table''s typical packets, the phase''s per-packet figure, the packets a month and the months per 10-packet phase' $inShort

Write-Host '  three tiers only'
$tableLines = @($costPage | Where-Object { $_.StartsWith('|') })
Assert-That (-not ($costText -match 'Written for four review tiers')) 'the "Written for four review tiers" paragraph is gone' ''
Assert-That (-not @($tableLines | Where-Object { $_ -match '(?i)\btier[- ]4\b|\btiers 3 and 4\b|\b\d \((\d, )*4[,)]' }).Count) 'no table in cost.md has a tier-4 row or a round at tier 4' (@($tableLines | Where-Object { $_ -match '(?i)\btier[- ]4\b|\btiers 3 and 4\b|\b\d \((\d, )*4[,)]' }) -join "`n")
Assert-That ($costText -match 'GPT-6\.1 Sol in every class' -and $costText -match 'doubles the dispatcher''s and tier 3''s parts') 'the page states once that it assumes GPT-6.1 Sol in every class, and what a dearer strong class does' ''

Write-Host '  a finished packet'
$p = Invoke-CaseProbe @'
$ec = Merge-PwHashtable $script:Defaults @{}
$r1 = @{ Kind = 'round'; Round = 1; Tier = '2'; Lenses = 'correctness,tests'; Outcome = 'fix'; CreatedAt = '2026-11-01T01:00:00Z' }
$r2 = @{ Kind = 'round'; Round = 2; Tier = '3'; Lenses = 'tests'; Outcome = 'fix'; CreatedAt = '2026-11-01T02:00:00Z' }
$ask = @{ Kind = 'settle-request'; Round = 2; Outcome = 'settle'; CreatedAt = '2026-11-01T03:00:00Z' }
$check = @{ Kind = 'settle-check'; Round = 2; Outcome = 'settled'; CreatedAt = '2026-11-01T04:00:00Z' }
$r3 = @{ Kind = 'round'; Round = 3; Tier = '3'; Lenses = 'tests'; Outcome = 'fix'; CreatedAt = '2026-11-01T05:00:00Z' }
$pass = @{ Kind = 'round'; Round = 2; Tier = '3'; Lenses = 'tests'; Outcome = 'pass'; CreatedAt = '2026-11-01T02:00:00Z' }
$owner = @{ Kind = 'round'; Round = 3; Tier = '3'; Lenses = 'tests'; Outcome = 'needs-human'; CreatedAt = '2026-11-01T05:00:00Z' }
$bare = [pscustomobject]@{ Round = 3; Tier = '3'; Lenses = 'tests'; Outcome = 'fix'; CreatedAt = '2026-11-01T05:00:00Z' }
$ask2 = @{ Kind = 'settle-request'; Round = 2; Outcome = 'settle'; CreatedAt = '2026-11-01T06:00:00Z' }
$sum = Get-PwCreditSummary -Config $ec -Today ([DateTime]'2026-11-01') -Packets @(
    [pscustomobject]@{ Id = 'SETTLED'; Size = 'S'; Pr = 1; Rounds = @($r1, $r2, $ask, $check) },
    [pscustomobject]@{ Id = 'ASKED'; Size = 'S'; Pr = 2; Rounds = @($r1, $r2, $ask) },
    [pscustomobject]@{ Id = 'REOPENED'; Size = 'S'; Pr = 3; Rounds = @($r1, $r2, $check, $r3) },
    [pscustomobject]@{ Id = 'FIXING'; Size = 'S'; Pr = 4; Rounds = @($r1, $r2) },
    [pscustomobject]@{ Id = 'PASSED'; Size = 'S'; Pr = 5; Rounds = @($r1, $pass) },
    [pscustomobject]@{ Id = 'OWNER'; Size = 'S'; Pr = 6; Rounds = @($r1, $r2, $owner) },
    [pscustomobject]@{ Id = 'BARE'; Size = 'S'; Pr = 7; Rounds = @($r1, $r2, $check, $bare) },
    [pscustomobject]@{ Id = 'ASKEDAGAIN'; Size = 'S'; Pr = 8; Rounds = @($r1, $r2, $ask, $check, $ask2) })
'finished=' + (($sum.Packets | ForEach-Object { "$($_.Id):$($_.Finished)" }) -join ',')
'avg=' + $sum.PerFinishedPacket + '|settled=' + ($sum.Packets | Where-Object Id -eq 'SETTLED').Credits + '|passed=' + ($sum.Packets | Where-Object Id -eq 'PASSED').Credits + '|owner=' + ($sum.Packets | Where-Object Id -eq 'OWNER').Credits + '|again=' + ($sum.Packets | Where-Object Id -eq 'ASKEDAGAIN').Credits
'@
Assert-That ($p.Code -eq 0 -and $p.Text -match 'finished=SETTLED:True,ASKED:False,REOPENED:False,FIXING:False,PASSED:True,OWNER:True,BARE:False,ASKEDAGAIN:True') 'a settle check after the last round finishes a packet whose last round says fix, even with a later settle request; a settle request alone, or a round after the check (with or without Kind), does not; pass and needs-human still finish' $p.Text
$avgOk = $p.Text -match 'avg=(\d+)\|settled=(\d+)\|passed=(\d+)\|owner=(\d+)\|again=(\d+)' -and [int]$Matches[1] -eq [Math]::Round(([int]$Matches[2] + [int]$Matches[3] + [int]$Matches[4] + [int]$Matches[5]) / 4)
Assert-That $avgOk 'the average per finished packet counts the settled packet' $p.Text

Write-Host '  the solo profile'
$soloPath = (Join-Path $kit 'templates/packet-workflow.solo.json').Replace("'", "''")
$soloBlock = if ($costText -match '(?s)## Solo profile.*?```json\s*(\{.*?\})\s*```') { $Matches[1] } else { '{}' }
$jsonPath = Join-Path ([System.IO.Path]::GetTempPath()) "pw-costdoc-$([guid]::NewGuid().ToString('n').Substring(0, 8)).json"
[System.IO.File]::WriteAllText($jsonPath, $soloBlock, [System.Text.UTF8Encoding]::new($false))
try {
    $p = Invoke-CaseProbe @"
$sortedJson
`$o = Get-Content -Raw '$soloPath' | ConvertFrom-Json -AsHashtable
'overlay=' + (Sort-Deep `$o | ConvertTo-Json -Depth 6 -Compress)
'page=' + (Sort-Deep (Get-Content -Raw '$($jsonPath.Replace("'", "''"))' | ConvertFrom-Json -AsHashtable) | ConvertTo-Json -Depth 6 -Compress)
'rates=' + [bool](`$o.budget -is [System.Collections.IDictionary] -and `$o.budget.Contains('creditsPerRun'))
"@
} finally { Remove-Item -LiteralPath $jsonPath -ErrorAction SilentlyContinue }
$ov = if ($p.Text -match '(?m)^overlay=(.*)$') { $Matches[1].Trim() } else { 'none' }
$pg = if ($p.Text -match '(?m)^page=(.*)$') { $Matches[1].Trim() } else { '' }
Assert-That ($p.Code -eq 0 -and $ov -eq $pg) 'the solo section''s config is templates/packet-workflow.solo.json, exactly' $p.Text
Assert-That ($p.Text -match '(?m)^rates=False') 'the solo overlay sets no creditsPerRun, so it prices on the defaults the page uses' $p.Text

$solo = & $tableAfter 'Credits per packet under the solo profile'
Assert-That ($solo.Count -eq 9) 'cost.md has the nine rows of "Credits per packet under the solo profile"' ($solo | ForEach-Object { $_ -join ' | ' } | Out-String)
$soloCases = @(foreach ($row in $solo) {
        $tiers = @(if ($row[1] -match '\(([\d,\s]+)\)') { $Matches[1] -split ',\s*' | ForEach-Object { [int]$_ } })
        $lenses = @($row[2] -split ',\s*' | ForEach-Object { [int]$_ })
        $runs = @($row[3] -split ',\s*' | ForEach-Object { [int]$_ })
        $size = if ($row[0] -match '^(S|M|L),') { $Matches[1] } else { '?' }
        [pscustomobject]@{ Name = $row[0]; Size = $size; Tiers = $tiers; Lenses = $lenses; Runs = $runs; Resume = (& $num $row[7]); Total = (& $num $row[8]); Parts = (& $num $row[4]) + (& $num $row[5]) + (& $num $row[6]) + (& $num $row[7]) }
    })
$body = '$ec = Merge-PwHashtable $script:Defaults @{}' + "`n"
foreach ($c in $soloCases) {
    $rounds = for ($i = 0; $i -lt $c.Tiers.Count; $i++) {
        $names = (1..$c.Lenses[$i] | ForEach-Object { "lens$_" }) -join ','
        "@{ Kind = 'round'; Round = $($i + 1); Tier = '$($c.Tiers[$i])'; Lenses = '$names'; Runs = '$($c.Runs[$i])'; Outcome = '$(if ($i -lt $c.Tiers.Count - 1) { 'fix' } else { 'pass' })' }"
    }
    $body += "'$($c.Name)=' + (Get-PwCreditEstimate -Config `$ec -Size '$($c.Size)' -Rounds @($($rounds -join ', '))).Credits`n"
}
$p = Invoke-CaseProbe $body
foreach ($c in $soloCases) {
    $est = if ($p.Text -match "(?m)^$([regex]::Escape($c.Name))=(\d+)") { [double]$Matches[1] + $c.Resume } else { -1 }
    # Three lenses share a run (review.lensesPerReviewer 3): the runs must be the lenses over 3, rounded up.
    $shape = $c.Tiers.Count -ge 1 -and $c.Tiers.Count -le 2 -and $c.Tiers.Count -eq $c.Lenses.Count -and $c.Runs.Count -eq $c.Lenses.Count -and
        -not @(for ($i = 0; $i -lt $c.Runs.Count; $i++) { if ($c.Runs[$i] -ne [Math]::Ceiling($c.Lenses[$i] / 3)) { $i } }).Count
    $tierOk = if ($c.Name -match 'forced') { -not @($c.Tiers | Where-Object { $_ -ne 3 }).Count } else { -not @($c.Tiers | Where-Object { $_ -ne 2 }).Count }
    Assert-That ($shape -and $tierOk -and $c.Total -gt 0 -and [Math]::Abs($est - $c.Total) -le 0.01 * $c.Total) "cost.md's solo $($c.Name) ($($c.Total)) is a two-round-at-most shape at the solo tiers, within 1% of Get-PwCreditEstimate on the default rates plus its resume share ($est)" $p.Text
    Assert-That ([Math]::Abs($c.Parts - $c.Total) -le 5) "cost.md's solo $($c.Name) row adds up: its parts make $($c.Parts), its total $($c.Total)" ''
}
$soloRow = @{}
foreach ($c in $soloCases) { if ($c.Name -match '^(S|M|L), (one clean round|typical|forced)') { $soloRow["$($Matches[1]) $($Matches[2])"] = $c.Total } }
$expected = @{}
foreach ($row in (& $tableAfter '**Expected per packet.**')) { $expected[$row[0]] = & $num $row[1] }
foreach ($sz in 'S', 'M', 'L') {
    $want = 0.11 * $soloRow["$sz one clean round"] + 0.89 * $soloRow["$sz typical"]
    Assert-That ($expected[$sz] -gt 0 -and [Math]::Abs($expected[$sz] - $want) -le 0.01 * $want) "the solo expected $sz packet ($($expected[$sz])) is 11% one clean round and 89% typical ($want)" ''
}
$adds = if ($costText -match 'adds about ([\d,]+) \(S\), ([\d,]+) \(M\) or ([\d,]+) \(L\)') { @((& $num $Matches[1]), (& $num $Matches[2]), (& $num $Matches[3])) } else { @(0, 0, 0) }
$addsOk = $adds[0] -eq $soloRow['S forced'] - $soloRow['S typical'] -and $adds[1] -eq $soloRow['M forced'] - $soloRow['M typical'] -and $adds[2] -eq $soloRow['L forced'] - $soloRow['L typical']
Assert-That $addsOk 'what a packet forced to tier 3 adds is the forced row less the typical one' ($adds -join ', ')
Assert-That ($costText -match 'S 950, M 1,500 and L 2,200') 'the solo section states the overlay''s ceilings' ''

$soloPhase = & $tableAfter 'A 10-packet phase (3 S, 5 M, 2 L)'
Assert-That ($soloPhase.Count -eq 2) 'cost.md has the solo phase table, typical and expected' ($soloPhase | ForEach-Object { $_ -join ' | ' } | Out-String)
$soloPer = 0
foreach ($row in $soloPhase) {
    $kind = if ($row[0] -match '^Typical') { 'typical' } elseif ($row[0] -match '^Expected') { 'expected' } else { '?' }
    $one = @{ S = 0; M = 0; L = 0 }
    foreach ($sz in 'S', 'M', 'L') { $one[$sz] = if ($kind -eq 'typical') { $soloRow["$sz typical"] } else { $expected[$sz] } }
    $packets = 3 * $one['S'] + 5 * $one['M'] + 2 * $one['L']
    $total = & $num $row[3]
    $ok = $kind -ne '?' -and [Math]::Abs((& $num $row[1]) - $packets) -le 10 -and (& $num $row[2]) -eq 350 -and [Math]::Abs($total - ($packets + 350)) -le 10 -and [Math]::Abs((& $num $row[4]) - $total / 10) -le 5
    Assert-That $ok "the solo $kind phase follows from the solo packets, plus 350 for planning, board and progress, and is one tenth of that a packet" ($row -join ' | ')
    if ($kind -eq 'expected') { $soloPer = & $num $row[4] }
}

$seats = & $tableAfter 'Packets a month on one seat'
$defaultPer = $tenTotal / 10
$seen = @{}
foreach ($row in $seats) {
    $credits = & $num $row[1]
    $seen[$row[0]] = $credits
    $perMonth = if ($soloPer -gt 0) { $credits / $soloPer } else { 0 }
    $range = if ($row[4] -match '^([\d.]+)\D+([\d.]+)$') { @([double]$Matches[1], [double]$Matches[2]) } else { @(-1, -1) }
    $ok = $soloPer -gt 0 -and [Math]::Abs((& $num $row[3]) - $perMonth) -le 0.05 -and [Math]::Abs((& $num $row[2]) - $credits / $defaultPer) -le 0.05 -and
        [Math]::Abs($range[0] - $perMonth / 1.75) -le 0.05 -and [Math]::Abs($range[1] - $perMonth / 0.6) -le 0.05
    Assert-That $ok "packets a month on $($row[0]) ($credits): solo is the credits over the solo per-packet figure ($soloPer), default over $defaultPer, and the range is that over 1.75 and 0.6" ($row -join ' | ')
}
Assert-That ($seen['Pro'] -eq 1500 -and $seen['Business'] -eq 1900 -and $seen['Enterprise'] -eq 3900) 'the seat table gives packets a month for Pro 1,500, Business 1,900 and Enterprise 3,900' (($seen.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', ')
Assert-That ($inShort -match "about $(& $fmt $soloPer) credits all in" -and $inShort -match "about $([Math]::Round(1500 / $soloPer, 1)) packets a month on Pro, $([Math]::Round(1900 / $soloPer, 1)) on Business") 'the "In short" solo bullet gives the solo per-packet figure and packets a month' $inShort
Assert-That ($costText -match '\| 8 \| \*\*Built:\*\*' -and $costText -match 'Change 8 is built, as `models\.agents`') 'lean change #8 is marked as built' ''
Assert-That ($costText -match 'forced raises still reach the top tier') 'the tier-floor property says the forced raises still reach the top tier under a cap' ''

Write-Host '  the README'
$readme = Get-Content -Raw -LiteralPath (Join-Path $kit 'README.md')
foreach ($key in 'models.agents', 'review.tierCap', 'budget.maxCreditsPerPacket') {
    Assert-That ($readme -match "(?m)^\| ``$([regex]::Escape($key))`` \|") "the README's Configure table has a row for $key" ''
}
Assert-That ($readme -notmatch 'what tier 4 cost' -and $readme -match 'The defaults are GPT-6\.1 Sol''s rates from \[cost\.md\]') 'the README''s creditsPerRun row describes PKT-7''s defaults, not the tier-4 pricing' ''
Assert-That ($readme -match '`\{ "S": 950, "M": 1500, "L": 2200 \}`, the solo profile''s') 'the README''s ceiling example is the solo overlay''s' ''
Assert-That ($readme -notmatch 'at least as capable as `packet-reviewer-deep`' -and $readme -match 'reason=model-tier') 'the Models bullet states the stop instead of telling the owner to raise the dispatcher''s model' ''
Assert-That ($readme -match '(?m)^\| The review tier is a floor \|' -and $readme -match 'reason=budget' -and $readme -match 'at most `review\.maxRounds` \(3\) rounds') 'the README has the tier-floor safety row, the budget stop and maxRounds in the ideas list' ''
$p = Invoke-CaseProbe @'
'defaults=' + ($null -eq $script:Defaults.review.tierCap) + ',' + ($null -eq $script:Defaults.budget.maxCreditsPerPacket) + ',' + $script:Defaults.models.agents.Count
'@
Assert-That ($p.Code -eq 0 -and $p.Text -match 'defaults=True,True,0') 'the defaults the README gives: no tier cap, no ceiling, no models.agents entries' $p.Text
foreach ($path in 'skills/packet-dispatch/scripts/credit-check.ps1', 'templates/packet-workflow.solo.json', 'skills/packet-review/scripts/review-scope.ps1') {
    Assert-That (Test-Path -LiteralPath (Join-Path $kit $path)) "the README names $path, and it exists" ''
}
