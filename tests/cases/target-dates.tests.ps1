# target-dates.tests.ps1: a packet Target that isn't a real date (2026-11-00, 2026-02-30) is rejected
# with a message naming the packet, by progress.ps1 (exit 2, no stack trace) and by validate-packets.ps1.
# Run by tests/run-tests.ps1 in a child scope: plain variables only, never a script-scope one, and kit
# code only through Invoke-CaseProbe (never dot-sourced here).

$tdProgress = Join-Path $skills 'packet-progress/scripts/progress.ps1'
$tdValidate = Join-Path $skills 'packet-plan/scripts/validate-packets.ps1'
$tdRepo = New-CaseRepo
Push-Location -LiteralPath $tdRepo
try {
    Write-Host '  bad Target dates'
    $r = Invoke-Kit $tdProgress @('-Json')
    Assert-That ($r.Code -eq 0) 'progress.ps1 reads the sample phase''s real Target dates' $r.Text
    # The dates it reads are the right days: PKT-01's Target is 2026-10-31 (W0), PKT-02's 2026-11-01 (W1).
    $r = Invoke-Kit $tdProgress @('-Json', '-Today', '2026-11-03')
    $late = @{}; foreach ($x in @(($r.Text | ConvertFrom-Json).Late)) { $late[$x.Id] = $x.DaysLate }
    Assert-That ($r.Code -eq 0 -and $late['PKT-01'] -eq 3 -and $late['PKT-02'] -eq 2) 'on 2026-11-03, PKT-01 is 3 days late and PKT-02 2 days' $r.Text
    $r = Invoke-Kit $tdProgress @('-Json', '-Today', '2026-10-30')
    $soon = @{}; foreach ($x in @(($r.Text | ConvertFrom-Json).DueSoon)) { $soon[$x.Id] = $x.DaysLeft }
    Assert-That ($r.Code -eq 0 -and $soon['PKT-01'] -eq 1 -and $soon['PKT-02'] -eq 2 -and @(($r.Text | ConvertFrom-Json).Late).Count -eq 0) 'on 2026-10-30, PKT-01 is due in 1 day and PKT-02 in 2, and nothing is late' $r.Text
    foreach ($bad in '2026-11-00', '2026-02-30') {
        $file = Join-Path $tdRepo 'docs/plan/phase-1/packets/PKT-02.md'
        $text = [System.IO.File]::ReadAllText($file) -replace '\*\*Target:\*\* \S+', "**Target:** $bad"
        [System.IO.File]::WriteAllText($file, $text, [System.Text.UTF8Encoding]::new($false))
        & git add -A; & git commit -qm "PKT-02 Target $bad" | Out-Null; & git push -q origin main 2>$null; & git fetch -q origin
        $r = Invoke-Kit $tdProgress @('-Json')
        Assert-That ($r.Code -eq 2 -and $r.Text -match "PKT-02 \(.*PKT-02\.md\): Target must be a date as yyyy-MM-dd \(got '$bad'\)" -and $r.Text -notmatch 'ParseExact|at <ScriptBlock>') "progress.ps1 rejects Target $bad with exit 2 and a message naming the packet, not a stack trace" $r.Text
        $r = Invoke-Kit $tdValidate @('-Phase', 'phase-1')
        Assert-That ($r.Code -eq 1 -and $r.Text -match "Target must be a date as yyyy-MM-dd \(got '$bad'\)") "validate-packets.ps1 reports Target $bad as an error" $r.Text
    }
}
finally {
    Pop-Location
    Remove-CaseRepo $tdRepo
}
