# cost-doc.tests.ps1 (PKT-7): docs/cost.md's figures against the estimator on the default rates, the
# default creditsPerRun in the template, the defaults and the page, and Get-PwCreditSummary's rule for a
# finished packet. Run by tests/run-tests.ps1 in a child scope: plain variables only, never a script-scope
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
$jsonBlock = if ($costText -match '(?s)```json\s*(\{.*?\})\s*```') { $Matches[1] } else { '{}' }
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
Assert-That ($tenTotal -gt 0 -and $costText -match "about $([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:N0}', $tenTotal / 10)) credits \(US\`$$([Math]::Round($tenTotal / 1000))\)" -and $costText -match "about $([Math]::Round(12500 / ($tenTotal / 10), 1)) packets") 'per packet all in is the 10-packet phase over ten, and the packets a month follow from it' "10-packet phase $tenTotal"
Assert-That ($tenTotal -ge 21000 -and $tenTotal -le 22000 -and $costText -match '`packet-plan` about 200 \(5 packets\), 275 \(10\)') 'about 2,160 a packet all in, with packet-plan at about 275 for 10 packets' "10-packet phase $tenTotal"

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
$sum = Get-PwCreditSummary -Config $ec -Today ([DateTime]'2026-11-01') -Packets @(
    [pscustomobject]@{ Id = 'SETTLED'; Size = 'S'; Pr = 1; Rounds = @($r1, $r2, $ask, $check) },
    [pscustomobject]@{ Id = 'ASKED'; Size = 'S'; Pr = 2; Rounds = @($r1, $r2, $ask) },
    [pscustomobject]@{ Id = 'REOPENED'; Size = 'S'; Pr = 3; Rounds = @($r1, $r2, $check, $r3) },
    [pscustomobject]@{ Id = 'FIXING'; Size = 'S'; Pr = 4; Rounds = @($r1, $r2) },
    [pscustomobject]@{ Id = 'PASSED'; Size = 'S'; Pr = 5; Rounds = @($r1, $pass) })
'finished=' + (($sum.Packets | ForEach-Object { "$($_.Id):$($_.Finished)" }) -join ',')
'avg=' + $sum.PerFinishedPacket + '|settled=' + ($sum.Packets | Where-Object Id -eq 'SETTLED').Credits + '|passed=' + ($sum.Packets | Where-Object Id -eq 'PASSED').Credits
'@
Assert-That ($p.Code -eq 0 -and $p.Text -match 'finished=SETTLED:True,ASKED:False,REOPENED:False,FIXING:False,PASSED:True') 'a settle check after the last round finishes a packet whose last round says fix; a settle request alone, or a round after the check, does not' $p.Text
$avgOk = $p.Text -match 'avg=(\d+)\|settled=(\d+)\|passed=(\d+)' -and [int]$Matches[1] -eq [Math]::Round(([int]$Matches[2] + [int]$Matches[3]) / 2)
Assert-That $avgOk 'the average per finished packet counts the settled packet' $p.Text
