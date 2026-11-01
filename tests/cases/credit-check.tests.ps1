# credit-check.tests.ps1 (PKT-5): credit-check.ps1 against a ceiling, the packet:budget raise, and the
# budget rows of Get-PwGhRounds in board rounds and the estimates.
# Run by tests/run-tests.ps1 in a child scope: plain variables only, never a script-scope one, and kit
# code only through Invoke-CaseProbe or Invoke-Kit (never dot-sourced here).
#
# GitHub is stubbed offline. The scripts load github-common.ps1 themselves, which would replace a stubbed
# Invoke-PwGh or Invoke-PwGhPages, so the stub sits one call below them: a gh function in the probe,
# which Invoke-PwGh's `& gh` finds ahead of any gh on PATH. It answers the sign-in, pr list and a PR's
# comments from a JSON file, logs every call, and fails when told to (or when asked anything else).

$creditCheck = Join-Path $skills 'packet-dispatch/scripts/credit-check.ps1'
$caseBoard = Join-Path $skills 'packet-board/scripts/board.ps1'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pw-credit-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false)
$ghLog = Join-Path $tmp 'gh-calls.log'
$quote = { param([string]$s) "'" + $s.Replace("'", "''") + "'" }

$ghStub = @'
$global:ccGh = Get-Content -Raw -LiteralPath @DATA@ | ConvertFrom-Json -AsHashtable
$global:ccLog = @LOG@
function global:gh {
    $a = @($args)
    Add-Content -LiteralPath $global:ccLog -Value ($a -join ' ')
    $d = $global:ccGh
    $global:LASTEXITCODE = 1
    if ($d['fail']) { return }
    if ($a[0] -eq 'api' -and $a -contains 'user') { $global:LASTEXITCODE = 0; return [string]$d['login'] }
    if ($a[0] -eq 'pr' -and $a[1] -eq 'list') { $global:LASTEXITCODE = 0; return (ConvertTo-Json -InputObject @($d['prs']) -Depth 6) }
    $path = @($a | Where-Object { "$_" -match '/issues/\d+/comments' })[0]
    if ($a[0] -eq 'api' -and $path -match '/issues/(\d+)/comments') {
        $global:LASTEXITCODE = 0
        $rows = if ($d['comments'] -and $d['comments'].Contains($Matches[1])) { @($d['comments'][$Matches[1]]) } else { @() }
        return (ConvertTo-Json -InputObject @(, $rows) -Depth 8)
    }
}
'@

function Invoke-WithGh([string]$Script, [string[]]$ScriptArgs, [hashtable]$Gh) {
    <# Runs a kit script in a probe with the gh stub; returns Code, Text and the gh calls it made. #>
    $data = Join-Path $tmp "gh-$([guid]::NewGuid().ToString('n')).json"
    [System.IO.File]::WriteAllText($data, (ConvertTo-Json -InputObject $Gh -Depth 10), $utf8)
    Remove-Item -LiteralPath $ghLog -ErrorAction SilentlyContinue
    # Parameter names go in bare: quoted, '-Pr' would be a positional string.
    $argText = ($ScriptArgs | ForEach-Object { if ($_ -cmatch '^-[A-Za-z]+$') { $_ } else { & $quote $_ } }) -join ' '
    $body = $ghStub.Replace('@DATA@', (& $quote $data)).Replace('@LOG@', (& $quote $ghLog)) + "`n& $(& $quote $Script) $argText`nexit `$LASTEXITCODE"
    $r = Invoke-CaseProbe $body
    $calls = @(if (Test-Path -LiteralPath $ghLog) { Get-Content -LiteralPath $ghLog })
    [pscustomobject]@{ Code = $r.Code; Text = $r.Text; Calls = $calls }
}
function Invoke-Check([string[]]$CheckArgs, [hashtable]$Gh) { Invoke-WithGh $creditCheck $CheckArgs $Gh }

# A marker comment as GitHub's REST API lists it.
function New-Comment([int]$Id, [string]$Login, [string]$Marker, [string]$At) {
    @{ id = $Id; user = @{ login = $Login }; body = "``packet:$Marker`` from the test"; created_at = $At; html_url = "https://example.test/c/$Id" }
}

# 0.1.1's credits per run, set in each base's own config so a change to the defaults (PKT-7) can't move
# these numbers. On them, an S packet's base is 50 + 105 = 155, and round 1 below (tier 2, 3 lenses in 1
# run, fix) is 300 + 35 + 50 x (1 + 0.4 x 2) + 40 = 465: so far 620. Round 2 (tier 2, 2 lenses, 1 run) is
# 300 + 35 + 0.85 x 50 x 1.4 = 394.5, booked as 394: total 1014.
$rates011 = @{
    dispatcher = 50; dispatcherPerRound = @{ S = 300; M = 330; L = 390 }; dispatcherPerReviewerRun = 35
    implementer = @{ S = 105; M = 200; L = 355 }; implementerFix = @{ S = 40; M = 55; L = 75 }
    reviewerByTier = @{ S = @(20, 50, 195); M = @(30, 70, 280); L = @(40, 95, 380) }; laterRoundFactor = 0.85
}
$round1Fix = 'round 1 head=aaa tier=2 lenses=security,correctness,tests runs=1 confirmed=correctness outcome=fix'
$round1Pass = 'round 1 head=aaa tier=2 lenses=security,correctness,tests runs=1 confirmed=- outcome=pass'
$r1 = New-Comment 1 'owner' $round1Fix '2026-10-01T10:00:00Z'
$gh = @{
    login    = 'owner'
    prs      = @(@{ number = 21; headRefName = 'pkt/pkt-03-api-endpoints'; baseRefName = 'main'; url = 'https://example.test/pull/21'; state = 'OPEN'; isDraft = $false; headRefOid = 'aaa' })
    comments = @{
        '20' = @()
        '21' = @($r1)
        '22' = @($r1, (New-Comment 2 'teammate' 'budget max=2000' '2026-10-02T08:00:00Z'))
        '23' = @($r1, (New-Comment 2 'mallory' 'budget max=2000' '2026-10-02T08:00:00Z'))
        '24' = @($r1, (New-Comment 2 'exmate' 'budget max=2000' '2026-10-02T08:00:00Z'))
        '25' = @($r1, (New-Comment 2 'teammate' 'budget max=800' '2026-10-02T08:00:00Z'))
        '26' = @($r1, (New-Comment 2 'teammate' 'budget max=lots' '2026-10-02T08:00:00Z'))
        '27' = @(New-Comment 1 'owner' $round1Pass '2026-10-01T10:00:00Z')
        '28' = @($r1, (New-Comment 2 'Teammate' 'budget max=lots' '2026-10-02T08:00:00Z'), (New-Comment 3 'teammate' 'budget max=2000' '2026-10-03T08:00:00Z'))
        '29' = @($r1, (New-Comment 2 'teammate' 'budget max=2000' '2026-10-02T08:00:00Z'), (New-Comment 3 'owner' 'round 2 head=bbb tier=3 lenses=correctness runs=1 confirmed=- outcome=pass' '2026-10-03T08:00:00Z'))
    }
}
$ghFail = @{ fail = $true }
$round2 = @('-Next', 'round', '-Round', '2', '-Tier', '2', '-Lenses', 'security,correctness', '-Runs', '1')

$caseRepo = New-CaseRepo
try {
    Push-Location -LiteralPath $caseRepo
    try {
        $git = { $out = & git @args 2>&1; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed: $out" } }
        $cfgFile = Join-Path $caseRepo '.github/packet-workflow.json'
        $pk3 = Join-Path $caseRepo 'docs/plan/phase-1/packets/PKT-03.md'
        $mainPk3 = [System.IO.File]::ReadAllText($pk3)
        # origin's default branch trusts teammate (and the GitHub sign-in, owner) for markers.
        $mainCfg = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json -AsHashtable
        $mainCfg.trustedAuthors = @('teammate')
        [System.IO.File]::WriteAllText($cfgFile, ($mainCfg | ConvertTo-Json -Depth 10), $utf8)
        & $git commit -qam 'trust teammate'
        & $git push -q origin main
        & $git fetch -q origin

        # A base: a branch off main whose config (and PKT-03's Size) the check reads at the merge base.
        # It trusts exmate too, whom origin's default branch doesn't: that list must not count.
        $newBase = {
            param([string]$Name, $Ceiling, [string]$Size = 'S', [scriptblock]$Edit = $null, [string]$From = 'main')
            & $git switch -q -c $Name $From
            $c = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json -AsHashtable
            $c.trustedAuthors = @('teammate', 'exmate')
            # A fresh copy each time, so an edit below can't reach the next base's rates.
            $c.budget.creditsPerRun = ConvertTo-Json -InputObject $rates011 -Depth 5 | ConvertFrom-Json -AsHashtable
            $c.budget.maxCreditsPerPacket = $Ceiling
            if ($Edit) { & $Edit $c }
            [System.IO.File]::WriteAllText($cfgFile, (ConvertTo-Json -InputObject $c -Depth 10), $utf8)
            [System.IO.File]::WriteAllText($pk3, ($mainPk3 -replace '\*\*Size:\*\* M', "**Size:** $Size"), $utf8)
            & $git commit -qam "base $Name"
            & $git switch -q main
        }
        $at = { param([string]$Name) @('-Base', $Name, '-Head', $Name) }
        $estimate = {
            # Get-PwCreditEstimate's credits for these rows, with the config at that ref.
            param([string]$Ref, [string]$Size, [string]$RowsJson)
            $p = Invoke-CaseProbe "`$c = Get-PwConfig -Ref '$Ref'; `$rows = @('$($RowsJson.Replace("'", "''"))' | ConvertFrom-Json); (Get-PwCreditEstimate -Config `$c -Size '$Size' -Rounds `$rows).Credits"
            [double]($p.Text.Trim() -split "`n")[-1]
        }
        $row1 = '{ "Kind": "round", "Round": 1, "Tier": "2", "Lenses": "security,correctness,tests", "Runs": "1", "Outcome": "fix" }'
        $row1Pass = '{ "Kind": "round", "Round": 1, "Tier": "2", "Lenses": "security,correctness,tests", "Runs": "1", "Outcome": "pass" }'

        Write-Host '  ceiling unset: OFF'
        $offArgs = @('-Packet', 'PKT-99', '-Base', 'main') + $round2
        $r = Invoke-Check $offArgs $ghFail
        Assert-That ($r.Code -eq 0 -and $r.Text -match '(?m)^OFF' -and $r.Calls.Count -eq 0) 'with maxCreditsPerPacket null it prints OFF and exits 0, with no gh call, for a packet with no file at the base' "$($r.Text)`ncalls: $($r.Calls -join ' | ')"
        $r = Invoke-Check (@('-Packet', 'PKT-99', '-Base', 'main', '-Next', 'fix', '-Json')) $ghFail
        $j = try { $r.Text | ConvertFrom-Json } catch { $null }
        Assert-That ($r.Code -eq 0 -and $j -and $j.Result -eq 'OFF' -and $r.Calls.Count -eq 0) 'OFF in -Json, -Next fix, no gh call' $r.Text
        & $newBase 'off-nokey' $null -Edit { param($c) $c.budget.Remove('maxCreditsPerPacket') }
        & $newBase 'off-notable' $null -Edit { param($c) $c.budget = 5 }
        & $newBase 'off-list' $null -Edit { param($c) $c.budget = @(1500) }
        foreach ($b in 'off-nokey', 'off-notable', 'off-list') {
            $r = Invoke-Check (@('-Packet', 'PKT-99') + (& $at $b) + @('-Next', 'start')) $ghFail
            Assert-That ($r.Code -eq 0 -and $r.Text -match '(?m)^OFF' -and $r.Calls.Count -eq 0) "OFF when the base's budget is $b (Get-PwCreditCeiling's rule for unset)" $r.Text
        }

        Write-Host '  WITHIN and OVER'
        & $newBase 'c1200' 1200
        & $newBase 'c900' 900
        & $newBase 'c1014' 1014
        $soFar = & $estimate 'c1200' 'S' "[$row1]"
        $total = & $estimate 'c1200' 'S' "[$row1, { `"Kind`": `"round`", `"Round`": 2, `"Tier`": `"2`", `"Lenses`": `"security,correctness`", `"Runs`": `"1`", `"Outcome`": `"pass`" }]"
        Assert-That ($soFar -eq 620 -and $total -eq 1014) 'on the test''s own 0.1.1 rates the estimator gives 620 so far and 1014 with round 2' "so far $soFar, total $total"
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Pr', '21') + (& $at 'c1200') + $round2) $gh
        Assert-That ($r.Code -eq 0 -and $r.Text -match "(?m)^WITHIN so-far=$soFar step=$($total - $soFar) total=$total ceiling=1200 \(config\)$") '-Next round within a ceiling of 1200: WITHIN, with so-far, step and total as Get-PwCreditEstimate gives them' $r.Text
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Pr', '21') + (& $at 'c900') + $round2) $gh
        Assert-That ($r.Code -eq 3 -and $r.Text -match "(?m)^OVER so-far=620 step=394 total=1014 ceiling=900 \(config\)$") 'a ceiling of 900, between so-far and total, prints OVER and exits 3' $r.Text
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Pr', '21') + (& $at 'c1014') + $round2) $gh
        Assert-That ($r.Code -eq 0 -and $r.Text -match '(?m)^WITHIN .*total=1014 ceiling=1014 ') 'a total equal to the ceiling is WITHIN' $r.Text
        $r = Invoke-Check (@('-Packet', 'pkt-03') + (& $at 'c900') + $round2 + @('-Json')) $gh
        $j = try { $r.Text | ConvertFrom-Json } catch { $null }
        Assert-That ($r.Code -eq 3 -and $j -and $j.Result -eq 'OVER' -and $j.Pr -eq 21 -and $j.SoFar -eq 620 -and $j.Step -eq 394 -and $j.Total -eq 1014 -and $j.Ceiling -eq 900 -and $j.Source -eq 'config' -and $r.Calls -match '^pr list') 'without -Pr it finds the packet''s PR; -Json carries the same numbers and still exits 3' "$($r.Text)`ncalls: $($r.Calls -join ' | ')"
        Assert-That (-not ($r.Calls | Where-Object { $_ -match '-X|POST|PATCH|DELETE|comment' -and $_ -notmatch '/comments\?per_page' })) 'it never posts or changes anything on GitHub' ($r.Calls -join "`n")

        Write-Host '  per-size ceiling'
        & $newBase 'size-s' @{ S = 1200; M = 500 } -Size 'S'
        # The branch makes PKT-03 an M packet: the base's S still decides.
        & $git switch -q -c 'size-s-head' 'size-s'
        [System.IO.File]::WriteAllText($pk3, $mainPk3, $utf8)
        & $git commit -qam 'PKT-03 is M on the branch'
        & $git switch -q main
        & $newBase 'size-m' @{ S = 1200; M = 500 } -Size 'M'
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Pr', '21', '-Base', 'size-s', '-Head', 'size-s-head') + $round2) $gh
        Assert-That ($r.Code -eq 0 -and $r.Text -match '(?m)^WITHIN .*ceiling=1200 \(config\)$') 'a per-size ceiling uses the size at the base (S: 1200), not the branch''s (M: 500)' $r.Text
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Pr', '21') + (& $at 'size-m') + $round2) $gh
        Assert-That ($r.Code -eq 3 -and $r.Text -match '(?m)^OVER .*ceiling=500 \(config\)$') 'the same table for an M packet at the base gives M''s ceiling, and M''s rates' $r.Text

        Write-Host '  raises'
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Pr', '22') + (& $at 'c900') + $round2) $gh
        Assert-That ($r.Code -eq 0 -and $r.Text -match '(?m)^WITHIN so-far=620 step=394 total=1014 ceiling=2000 \(raised by teammate 2026-10-02\)$') 'a trusted packet:budget max=2000 turns OVER into WITHIN and names who raised it, and when' $r.Text
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Pr', '23') + (& $at 'c900') + $round2) $gh
        Assert-That ($r.Code -eq 3 -and $r.Text -match 'ceiling=900 \(config\)') 'the same raise from an untrusted login changes nothing' $r.Text
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Pr', '24') + (& $at 'c900') + $round2) $gh
        Assert-That ($r.Code -eq 3 -and $r.Text -match 'ceiling=900 \(config\)') 'nor from a login the base''s trustedAuthors lists but the default branch''s no longer does' $r.Text
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Pr', '25') + (& $at 'c900') + $round2) $gh
        Assert-That ($r.Code -eq 3 -and $r.Text -match 'ceiling=900 \(config\)') 'a raise below the configured ceiling changes nothing: a raise only ever raises' $r.Text
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Pr', '26') + (& $at 'c900') + $round2) $gh
        Assert-That ($r.Code -eq 2 -and $r.Text -match "credit-check: the raise by teammate .*max='lots'" -and $r.Text -notmatch 'WITHIN|OVER') 'a trusted max=lots exits 2' $r.Text
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Pr', '28') + (& $at 'c900') + $round2) $gh
        Assert-That ($r.Code -eq 0 -and $r.Text -match 'ceiling=2000 \(raised by teammate 2026-10-03\)') 'the newest trusted raise counts: a later max=2000 replaces an earlier max=lots' $r.Text
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Pr', '29') + (& $at 'c900') + @('-Next', 'round', '-Round', '3', '-Tier', '3', '-Lenses', 'correctness', '-Runs', '1')) $gh
        Assert-That ($r.Code -eq 0 -and $r.Text -match 'ceiling=2000 \(raised by teammate 2026-10-02\)') 'a raise holds for the rest of the packet, past later rounds' $r.Text

        Write-Host '  errors exit 2, never WITHIN'
        & $newBase 'typo' 1200 -Edit { param($c) $c.budget.creditsPerRun.dispatcher = 'fifty' }
        & $newBase 'broken' '1500'
        & $newBase 'negative' -5
        $cases = [ordered]@{
            'a creditsPerRun typo'                          = @{ Args = @('-Packet', 'PKT-03', '-Pr', '21') + (& $at 'typo') + $round2; Gh = $gh; Want = 'budget\.creditsPerRun\.dispatcher' }
            'a quoted ceiling'                              = @{ Args = @('-Packet', 'PKT-03', '-Pr', '21') + (& $at 'broken') + $round2; Gh = $gh; Want = 'budget\.maxCreditsPerPacket must be a positive number' }
            'a negative ceiling'                            = @{ Args = @('-Packet', 'PKT-03', '-Pr', '21') + (& $at 'negative') + $round2; Gh = $gh; Want = 'budget\.maxCreditsPerPacket must be a positive number' }
            'a failed gh call'                              = @{ Args = @('-Packet', 'PKT-03', '-Pr', '21') + (& $at 'c1200') + $round2; Gh = $ghFail; Want = 'gh api .* failed' }
            'no packet file at the base'                    = @{ Args = @('-Packet', 'PKT-99', '-Pr', '21') + (& $at 'c1200') + $round2; Gh = $gh; Want = 'no packet file for PKT-99 at the base' }
            'a -Round that skips one'                       = @{ Args = @('-Packet', 'PKT-03', '-Pr', '21') + (& $at 'c1200') + @('-Next', 'round', '-Round', '3', '-Tier', '2', '-Lenses', 'tests', '-Runs', '1'); Gh = $gh; Want = "-Round 3 isn't one more than the last round marker on PR #21 \(round 1\)" }
            'a -Round that repeats the last'                = @{ Args = @('-Packet', 'PKT-03', '-Pr', '21') + (& $at 'c1200') + @('-Next', 'round', '-Round', '1', '-Tier', '2', '-Lenses', 'tests', '-Runs', '1'); Gh = $gh; Want = "-Round 1 isn't one more" }
            '-Next round without -Runs'                     = @{ Args = @('-Packet', 'PKT-03', '-Pr', '21') + (& $at 'c1200') + @('-Next', 'round', '-Round', '2', '-Tier', '2', '-Lenses', 'tests'); Gh = $gh; Want = 'missing -Runs' }
            'more runs than lenses'                         = @{ Args = @('-Packet', 'PKT-03', '-Pr', '21') + (& $at 'c1200') + @('-Next', 'round', '-Round', '2', '-Tier', '2', '-Lenses', 'tests', '-Runs', '2'); Gh = $gh; Want = '-Runs must be from 1 to the number of lenses' }
            '-Next fix with no round yet'                   = @{ Args = @('-Packet', 'PKT-03', '-Pr', '20', '-Next', 'fix') + (& $at 'c1200'); Gh = $gh; Want = 'has no round marker' }
            'no PR for the packet'                          = @{ Args = @('-Packet', 'PKT-04', '-Next', 'fix') + (& $at 'c1200'); Gh = $gh; Want = 'no pull request for PKT-04' }
            '-Pr with -Next start'                          = @{ Args = @('-Packet', 'PKT-03', '-Pr', '21', '-Next', 'start') + (& $at 'c1200'); Gh = $gh; Want = '-Next start runs before the packet has a PR' }
        }
        foreach ($name in $cases.Keys) {
            $case = $cases[$name]
            $r = Invoke-Check $case.Args $case.Gh
            Assert-That ($r.Code -eq 2 -and $r.Text -match $case.Want -and $r.Text -notmatch '(?m)^(WITHIN|OVER|OFF)') "$name exits 2 with a message, never WITHIN" $r.Text
        }
        # Parameter binding, under pwsh -File as the dispatcher runs it.
        $r = Invoke-Kit $creditCheck @('-Base', 'c1200', '-Next', 'start')
        Assert-That ($r.Code -ne 0 -and $r.Code -ne 3 -and $r.Text -notmatch '(?m)^(WITHIN|OVER|OFF)') 'a missing -Packet exits non-zero, never 0 or 3' "exit $($r.Code): $($r.Text)"
        $r = Invoke-Kit $creditCheck @('-Packet', 'PKT-03', '-Base', 'c1200', '-Next', 'round', '-Round', 'abc', '-Tier', '2', '-Lenses', 'tests', '-Runs', '1')
        Assert-That ($r.Code -ne 0 -and $r.Code -ne 3 -and $r.Text -notmatch '(?m)^(WITHIN|OVER|OFF)') '-Round abc exits non-zero, never 0 or 3' "exit $($r.Code): $($r.Text)"
        $r = Invoke-Kit $creditCheck @('-Packet', 'PKT-03', '-Base', 'c1200', '-Next', 'later')
        Assert-That ($r.Code -ne 0 -and $r.Code -ne 3) 'a -Next that isn''t start, round or fix exits non-zero, never 0 or 3' "exit $($r.Code): $($r.Text)"

        Write-Host '  -Next fix and -Next start'
        # After a passed round (a CI fix): the fix run, which no marker books, plus a one-lens round at tier 2.
        $ciFix = & $estimate 'c1200' 'S' "[$row1Pass, { `"Kind`": `"round`", `"Round`": 2, `"Tier`": `"2`", `"Lenses`": `"correctness`", `"Runs`": `"1`", `"Outcome`": `"fix`" }]"
        $passed = & $estimate 'c1200' 'S' "[$row1Pass]"
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Pr', '27', '-Next', 'fix') + (& $at 'c1200')) $gh
        Assert-That ($r.Code -eq 0 -and $r.Text -match "(?m)^WITHIN so-far=$passed step=$($ciFix - $passed) total=$ciFix ") '-Next fix after a passed round prices the CI fix run and a one-lens round at that round''s tier' "want so-far=$passed total=$ciFix`n$($r.Text)"
        # After a fix round at tier 2, with no cap: the confirmed lens at tier 3, in round 2.
        $tier3 = & $estimate 'c1200' 'S' "[$row1, { `"Kind`": `"round`", `"Round`": 2, `"Tier`": `"3`", `"Lenses`": `"correctness`", `"Runs`": `"1`", `"Outcome`": `"pass`" }]"
        $tier2 = & $estimate 'c1200' 'S' "[$row1, { `"Kind`": `"round`", `"Round`": 2, `"Tier`": `"2`", `"Lenses`": `"correctness`", `"Runs`": `"1`", `"Outcome`": `"pass`" }]"
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Pr', '21', '-Next', 'fix') + (& $at 'c1200')) $gh
        Assert-That ($tier3 -gt $tier2 -and $r.Code -eq 0 -and $r.Text -match "(?m)^WITHIN so-far=620 step=$($tier3 - 620) total=$tier3 ") '-Next fix after a fix round at tier 2 with no cap prices the next round at tier 3, with the confirmed lenses' "want total $tier3 (tier 2 would be $tier2)`n$($r.Text)"
        & $newBase 'cap2' 1200 -Edit { param($c) $c.review.tierCap = 2 }
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Pr', '21', '-Next', 'fix') + (& $at 'cap2')) $gh
        Assert-That ($r.Code -eq 0 -and $r.Text -match "total=$tier2 ") 'with review.tierCap 2 at the base it stays at tier 2' "want total $tier2`n$($r.Text)"
        & $newBase 'per2' 1200 -Edit { param($c) $c.review.lensesPerReviewer = 2 }
        $grouped = & $estimate 'per2' 'S' "[$row1Pass, { `"Kind`": `"round`", `"Round`": 2, `"Tier`": `"2`", `"Lenses`": `"correctness`", `"Runs`": `"1`", `"Outcome`": `"fix`" }]"
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Pr', '27', '-Next', 'fix') + (& $at 'per2')) $gh
        Assert-That ($r.Code -eq 0 -and $r.Text -match "total=$grouped ") '-Next fix reads the base''s config for the round it prices' $r.Text
        $start = & $estimate 'c1200' 'S' '[{ "Kind": "round", "Round": 1, "Tier": "1", "Lenses": "correctness", "Runs": "1", "Outcome": "pass" }]'
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Next', 'start') + (& $at 'c1200')) $ghFail
        Assert-That ($r.Code -eq 0 -and $r.Text -match "(?m)^WITHIN so-far=0 step=$start total=$start ceiling=1200 \(config\)$" -and $r.Calls.Count -eq 0) '-Next start prices the base and a one-lens round at tier 1, with no PR and no gh call' $r.Text
        & $newBase 'c300' 300
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Next', 'start') + (& $at 'c300')) $ghFail
        Assert-That ($r.Code -eq 3 -and $r.Text -match "(?m)^OVER so-far=0 step=$start total=$start ceiling=300 ") 'a ceiling no packet of that size can meet stops it at -Next start' $r.Text

        Write-Host '  the base decides'
        & $newBase 'c500' 500
        & $git switch -q -c 'c500-head' 'c500'
        $c = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json -AsHashtable
        $c.budget.maxCreditsPerPacket = 99999
        [System.IO.File]::WriteAllText($cfgFile, (ConvertTo-Json -InputObject $c -Depth 10), $utf8)
        & $git commit -qam 'the branch raises its own ceiling'
        $r = Invoke-Check (@('-Packet', 'PKT-03', '-Pr', '21', '-Base', 'c500') + $round2) $gh
        Assert-That ($r.Code -eq 3 -and $r.Text -match 'ceiling=500 \(config\)') 'a ceiling of 500 at the base and 99999 in the branch''s config gives OVER' $r.Text
        & $git switch -q main

        Write-Host '  budget rows in board rounds and the estimates'
        $r = Invoke-WithGh $caseBoard @('rounds', '22') $gh
        Assert-That ($r.Code -eq 0 -and $r.Text -match '(?m)^round 1 head=aaa tier=2 outcome=fix ' -and $r.Text -match '(?m)^budget 1 max=2000 by teammate$') 'board rounds prints the budget row as budget <round> max=<n> by <login>' $r.Text
        $r = Invoke-WithGh $caseBoard @('rounds', '23') $gh
        Assert-That ($r.Code -eq 0 -and $r.Text -notmatch 'budget') 'an untrusted budget comment is no row' $r.Text
        $r = Invoke-WithGh $caseBoard @('rounds', '28', '-Json') $gh
        $rows = try { @($r.Text | ConvertFrom-Json) } catch { @() }
        $budgetRows = @($rows | Where-Object Kind -eq 'budget')
        $shape = @($budgetRows | Where-Object { $_.Outcome -eq 'budget' -and $null -eq $_.Tier -and $null -eq $_.Lenses -and $null -eq $_.Runs -and $null -eq $_.Confirmed -and $null -eq $_.Head -and $_.Round -eq 1 -and $_.Consumed -eq $false })
        Assert-That ($r.Code -eq 0 -and $rows.Count -eq 3 -and $budgetRows.Count -eq 2 -and $shape.Count -eq 2 -and (($budgetRows | ForEach-Object Max) -join ',') -eq 'lots,2000') 'board rounds -Json lists budget rows with settle rows'' properties, Outcome budget and Max as written' $r.Text
        $rowsFile = Join-Path $tmp 'rows-28.json'
        [System.IO.File]::WriteAllText($rowsFile, $r.Text, $utf8)
        $p = Invoke-CaseProbe @"
`$c = Get-PwConfig -Ref 'c1200'
`$all = @(Get-Content -Raw -LiteralPath '$($rowsFile.Replace("'", "''"))' | ConvertFrom-Json)
`$plain = @(`$all | Where-Object Kind -ne 'budget')
`$a = Get-PwCreditEstimate -Config `$c -Size 'S' -Rounds `$all; `$b = Get-PwCreditEstimate -Config `$c -Size 'S' -Rounds `$plain
`$sa = Get-PwCreditSummary -Config `$c -Today ([DateTime]'2026-10-20') -Packets @([pscustomobject]@{ Id = 'PKT-03'; Size = 'S'; Pr = 28; Rounds = `$all })
`$sb = Get-PwCreditSummary -Config `$c -Today ([DateTime]'2026-10-20') -Packets @([pscustomobject]@{ Id = 'PKT-03'; Size = 'S'; Pr = 28; Rounds = `$plain })
"with=`$(`$a.Credits)/`$(`$a.Rounds.Count)/`$(`$sa.Total)/`$(`$sa.ThisMonth)|without=`$(`$b.Credits)/`$(`$b.Rounds.Count)/`$(`$sb.Total)/`$(`$sb.ThisMonth)"
"@
        $m = [regex]::Match($p.Text, 'with=(?<a>\S+)\|without=(?<b>\S+)')
        Assert-That ($p.Code -eq 0 -and $m.Success -and $m.Groups['a'].Value -eq $m.Groups['b'].Value -and $m.Groups['a'].Value -eq '620/1/620/620') 'Get-PwCreditEstimate and Get-PwCreditSummary give the same totals with budget rows among the markers as without' $p.Text
    }
    finally { Pop-Location }
}
finally {
    Remove-CaseRepo $caseRepo
    if (-not $Keep) { Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue }
}
