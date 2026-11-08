# stops.tests.ps1 (PKT-6): the credit-ceiling and model-tier stops in the dispatch and review skills, the
# narrow settle, the two Needs human first lines (parsed by Get-PwMarker and read back by board marker on
# the local board), and the commands the skills give, run against credit-check.ps1.
# Run by tests/run-tests.ps1 in a child scope: plain variables only, never a script-scope one, and kit
# code only through Invoke-Kit, Invoke-CaseProbe or New-CaseRepo (never dot-sourced here).
#
# These are instructions, so most checks pin their wording, as the guard tests in run-tests.ps1 do: an
# edit that drops or inverts a rule fails here rather than in a live run.

$lf = { param([string]$Path) (Get-Content -Raw -LiteralPath $Path).Replace("`r`n", "`n") }
$dispatch = & $lf (Join-Path $skills 'packet-dispatch/SKILL.md')
$review = & $lf (Join-Path $skills 'packet-review/SKILL.md')
$template = & $lf (Join-Path $skills 'packet-review/round-report-template.md')
$agent = & $lf (Join-Path $kit 'agents/packet-dispatcher.agent.md')
$creditCheck = Join-Path $skills 'packet-dispatch/scripts/credit-check.ps1'
$caseBoard = Join-Path $skills 'packet-board/scripts/board.ps1'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$quote = { param([string]$s) "'" + $s.Replace("'", "''") + "'" }

# A section's body: from its heading line to the next heading of the same level or higher.
function Get-StopSection([string]$Text, [string]$Heading) {
    $level = ($Heading -split ' ')[0].Length
    $m = [regex]::Match($Text, '(?ms)^' + [regex]::Escape($Heading) + '[ \t]*\n(.*?)(?=^#{1,' + $level + '} |\z)')
    if ($m.Success) { $m.Groups[1].Value } else { '' }
}
# Asserts that every phrase is in the text; names the missing ones.
function Assert-Phrases([string]$Text, [string[]]$Phrases, [string]$Name) {
    $missing = @($Phrases | Where-Object { -not $Text.Contains($_) })
    Assert-That ($Text.Length -gt 0 -and $missing.Count -eq 0) $Name ("missing:`n" + ($missing -join "`n"))
}
# Asserts that the phrases appear in this order.
function Assert-Order([string]$Text, [string[]]$Phrases, [string]$Name) {
    $at = @($Phrases | ForEach-Object { $Text.IndexOf($_, [StringComparison]::Ordinal) })
    $ok = -not ($at -contains -1)
    for ($i = 1; $ok -and $i -lt $at.Count; $i++) { if ($at[$i] -le $at[$i - 1]) { $ok = $false } }
    Assert-That $ok $Name ("positions: " + ($at -join ', ') + "`n" + ($Phrases -join "`n"))
}

$select = Get-StopSection $dispatch '## 1 · Select'
$rounds = Get-StopSection $dispatch '## 8 · Review rounds'
$handOff = Get-StopSection $dispatch '## 9 · Hand off'
$resume = Get-StopSection $dispatch '## Resume `<ID>`'
$afterStop = Get-StopSection $dispatch '### After a stop'
$needsHuman = Get-StopSection $dispatch '## Needs human'
$budgetStop = Get-StopSection $dispatch '### A budget stop'
$modelStop = Get-StopSection $dispatch '### A model-tier stop'
$settle = Get-StopSection $dispatch '## Settle'
$narrow = Get-StopSection $dispatch '### Before the last round: pass with follow-ups'
$never = Get-StopSection $dispatch '## Never'
$preflight = Get-StopSection $dispatch '## 0 · Preflight'
$reviewLimits = Get-StopSection $review '## The limits'
$review1 = Get-StopSection $review '## 1 · Tier and lenses'
$review2 = Get-StopSection $review '## 2 · Run the lenses, a pair at a time'
$review4 = Get-StopSection $review '## 4 · Report'
$agentNever = Get-StopSection $agent '## Never'
$agentSubagents = Get-StopSection $agent '## Subagents'

Write-Host '  the guards stay byte-identical'
# The base's sections, line endings made LF, hashed: the e2e prompt and run-tests.ps1 pin their text.
$guardHash = {
    param([string]$Text, [string]$Heading)
    $m = [regex]::Match($Text, '(?ms)^' + [regex]::Escape($Heading) + '\n.*?(?=^## )')
    [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($utf8.GetBytes($m.Value)))
}
Assert-That ((& $guardHash $dispatch '## Only a person starts a dispatch') -eq 'C9E04347F98B11EA79F90BC08DD4C5443813C56FBFA82F4DFA4244F97F665348') '## Only a person starts a dispatch is byte-identical to the base''s (up to ## Never)' ''
Assert-That ((& $guardHash $agent '## Only a person starts you') -eq 'B6A1133131DA576E72CCAA988D3FB5D6280FE51A2ED9A211BB40E1A78D465F67') '## Only a person starts you is byte-identical to the base''s' ''

Write-Host '  the checks before a claim, a fix run and a round'
Assert-Phrases $select @(
    '- **Credits,** last, before the claim.'
    '`credit-check …` here and below means `pwsh -File <kit>/.github/skills/packet-dispatch/scripts/credit-check.ps1 …`'
    'It prints `OFF` (no ceiling set) or `WITHIN` and exits 0, prints `OVER` and exits 3, and exits with any other code'
    'Only exit 0 goes on.'
    'never read it as a pass'
    '`credit-check -Packet <ID> -Base origin/<defaultBranch> -Head origin/<defaultBranch> -Next start`'
    '- Exit 0 (`OFF` or `WITHIN`): go on to step 2.'
    '- Exit 3 (`OVER`):'
    'If the owner named this packet, stop and tell them the line it printed.'
    'Otherwise take the next START line, as with an open contract question.'
    '- Any other exit: stop and report the error.'
    'Nothing is claimed yet, so none of these needs a release or a **Needs human**.') '§1 Select runs credit-check -Next start before the claim, and says what exit 0, 3 and any other code do'
Assert-Order $dispatch @('## 1 · Select', '-Next start`', '## 2 · Claim', 'board claim <ID> <claim-id>') 'the start check comes before step 2''s claim'
Assert-Phrases $rounds @(
    '1. **Credits,** before the implementer: `credit-check -Packet <ID> -Base origin/<the PR''s baseRefName> -Head HEAD -Pr <pr> -Next fix`.'
    '- Exit 0 (`OFF` or `WITHIN`): go on.'
    '- Exit 3 (`OVER`): **Needs human** with `reason=budget next=fix`. Nothing has been pushed since the round, so the PR head is still the one the panel reviewed.'
    '- Any other exit: stop and report the error, and release the claim.'
    '- **Stopped**: the round ended with no report and no question'
    'Nothing about a stopped round reads as a pass.') '§8 Fix runs credit-check -Next fix and says what exit 0, 3 and any other code do; a stopped round never passes'
Assert-Order $rounds @('- **Fix**:', '-Next fix`', '2. Run a new implementer', '- **Pass**:') 'the fix check comes before the implementer'
Assert-Phrases $rounds @(
    'Every implementer run after the PR opens goes through **Fix**, so its credit check runs first.'
    'That includes step 9.3''s CI fix after a round that passed, which credit-check prices as a CI fix'
    'and a fix the owner asks for in answer to a **Needs human**, priced the same way.'
    'After a settled round (**Settle**, before the last round), whose marker still says `outcome=fix`, the script prices a CI fix the same way, as it would after a round that passed.'
    'Every other round goes through the panel, whose own check (`-Next round`, packet-review §1) runs before its first pair'
    'step 9.2''s round for a conflict resolution, **Amend**''s round') '§8 says the CI fix, the conflict round and Amend''s round are each covered'
Assert-Phrases $handOff @('fix it like a review finding (step 8, **Fix**: the credit check, the implementer, push, a round for the fix)') '§9.3''s CI fix goes through §8 Fix'
Assert-Phrases $review1 @(
    '**The credit check.** After review-scope, and after any raise of your own, and before §2:'
    'pwsh -File <kit>/.github/skills/packet-dispatch/scripts/credit-check.ps1 -Packet <ID> -Base origin/<baseRefName> -Head <head sha> -Pr <pr> -Next round -Round <N> -Tier <this round''s tier> -Lenses <Lenses, joined with commas> -Runs <the number of Runs>'
    '- Exit 0 (`OFF` or `WITHIN`): go on to §2.'
    '- Exit 3 (`OVER`): this round would pass the ceiling. Check the claim, start no pair, `board set <ID> "Status=Needs human"`'
    'with `next=round`, `round=<N>`'
    'Post no round report. Return Needs human.'
    '- Any other exit: stop the round with no report and no Needs human'
    'Never start a pair on a check that failed.') 'packet-review §1 runs credit-check -Next round and says what exit 0, 3 and any other code do'
Assert-Order $review @('review-scope.ps1 -Base origin/<baseRefName>', 'credit-check.ps1 -Packet <ID>', '## 2 · Run the lenses') 'the round check runs after review-scope and before §2'
Assert-Phrases $reviewLimits @('6. **Credits:** a round starts only when `credit-check -Next round` (§1) says') 'the review skill''s limits add a sixth: the credit ceiling'

# Each check has exactly three exit bullets, exit 0, exit 3 and any other, and only exit 0 goes on: a
# fourth bullet (say, one that lets exit 2 through) fails here.
foreach ($c in @(@{ N = '§1 Select'; T = $select }, @{ N = '§8 Fix'; T = $rounds }, @{ N = 'packet-review §1'; T = $review1 })) {
    $bullets = @([regex]::Matches($c.T, '(?m)^[ \t]*- (?<label>Exit [^:]*|Any other exit)[^\n]*') | ForEach-Object { [pscustomobject]@{ Label = $_.Groups['label'].Value; Line = $_.Value } })
    $labels = @($bullets | ForEach-Object Label) -join ' | '
    $goOn = @($bullets | Where-Object { $_.Line -match '\bgo on\b' } | ForEach-Object Label)
    Assert-That ($labels -ceq 'Exit 0 (`OFF` or `WITHIN`) | Exit 3 (`OVER`) | Any other exit' -and ($goOn -join ',') -ceq 'Exit 0 (`OFF` or `WITHIN`)') "$($c.N)'s check has exactly the exit 0, exit 3 and any-other bullets, and only exit 0 goes on" ("labels: $labels`ngo on: $($goOn -join ', ')")
}

Write-Host '  the commands the skills give, run against credit-check.ps1'
# Each command, as the skill writes it, with its placeholders filled in. Its shape is checked before the
# config is read, so even OFF proves the call is well formed; a gh stub answers the PR's markers.
$fill = @{
    '<ID>' = 'PKT-03'; '<defaultBranch>' = 'main'; '<the PR''s baseRefName>' = 'main'; '<baseRefName>' = 'main'; '<pr>' = '21'
    '<head sha>' = 'HEAD'; '<N>' = '2'; '<this round''s tier>' = '2'; '<Lenses, joined with commas>' = 'security,correctness'; '<the number of Runs>' = '1'
}
$toArgs = {
    param([string]$Command)
    foreach ($k in $fill.Keys) { $Command = $Command.Replace($k, $fill[$k]) }
    , @($Command -split ' ' | Where-Object { $_ })
}
$startCmd = [regex]::Match($select, '`credit-check (-Packet [^`]*-Next start)`').Groups[1].Value
$fixCmd = [regex]::Match($rounds, '`credit-check (-Packet [^`]*-Next fix)`').Groups[1].Value
$roundLine = [regex]::Match($review1, '(?m)^pwsh -File <kit>/\.github/skills/(packet-dispatch/scripts/credit-check\.ps1) (-Packet .*-Next round .*)$')
$roundCmd = $roundLine.Groups[2].Value
$startArgs = & $toArgs $startCmd; $fixArgs = & $toArgs $fixCmd; $roundArgs = & $toArgs $roundCmd
$unfilled = @(@($startArgs) + @($fixArgs) + @($roundArgs) | Where-Object { $_ -match '[<>]' })
Assert-That ($startCmd -and $fixCmd -and $roundCmd -and $unfilled.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $skills $roundLine.Groups[1].Value))) 'the three commands are found, every placeholder fills, and the review skill names the kit''s credit-check.ps1' ("start: $startCmd`nfix: $fixCmd`nround: $roundCmd`nunfilled: $($unfilled -join ' ')")

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pw-stops-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
$ghLog = Join-Path $tmp 'gh-calls.log'
# The gh stub (as credit-check.tests.ps1's): the sign-in, a PR over REST, and its comments.
$ghStub = @'
$global:stGh = Get-Content -Raw -LiteralPath @DATA@ | ConvertFrom-Json -AsHashtable
$global:stLog = @LOG@
function global:gh {
    $a = @($args)
    Add-Content -LiteralPath $global:stLog -Value ($a -join ' ')
    $d = $global:stGh
    $global:LASTEXITCODE = 1
    if ($a[0] -eq 'api' -and $a -contains 'user') { $global:LASTEXITCODE = 0; return [string]$d['login'] }
    $pull = $a | Where-Object { "$_" -match '^repos/[^/]+/[^/]+/pulls/(\d+)$' } | Select-Object -First 1
    if ($a[0] -eq 'api' -and $pull -match '/pulls/(\d+)$') {
        $p = $d['prs'] | Where-Object { "$($_['number'])" -eq $Matches[1] } | Select-Object -First 1
        if (-not $p) { [Console]::Error.WriteLine('HTTP 404: Not Found'); return }
        $global:LASTEXITCODE = 0
        return (ConvertTo-Json -InputObject @{ number = $p['number']; state = 'open'; head = @{ ref = $p['headRefName'] } } -Depth 4)
    }
    $path = $a | Where-Object { "$_" -match '/issues/\d+/comments' } | Select-Object -First 1
    if ($a[0] -eq 'api' -and $path -match '/issues/(\d+)/comments') {
        $global:LASTEXITCODE = 0
        $rows = if ($d['comments'].Contains($Matches[1])) { @($d['comments'][$Matches[1]]) } else { @() }
        return (ConvertTo-Json -InputObject @(, $rows) -Depth 8)
    }
}
'@
$roundComment = { param([int]$Id, [string]$Marker) @{ id = $Id; user = @{ login = 'owner' }; body = "``packet:$Marker```n### Review panel"; created_at = '2026-11-01T10:00:00Z'; html_url = "https://example.test/c/$Id" } }
$gh = @{
    login    = 'owner'
    prs      = @(@{ number = 21; headRefName = 'pkt/pkt-03-api-endpoints' }, @{ number = 27; headRefName = 'pkt/pkt-03-api-endpoints' }, @{ number = 28; headRefName = 'pkt/pkt-03-api-endpoints' })
    comments = @{
        '21' = @(& $roundComment 1 'round 1 head=aaa tier=2 lenses=security,correctness runs=2 confirmed=security outcome=fix')
        '27' = @(& $roundComment 1 'round 1 head=aaa tier=2 lenses=security,correctness runs=2 confirmed=- outcome=pass')
        # Round 1 settled by the narrow settle: its marker still says outcome=fix, and a settle-check follows.
        '28' = @((& $roundComment 1 'round 1 head=aaa tier=2 lenses=security,correctness runs=2 confirmed=security outcome=fix'), (& $roundComment 2 'settle-check head=aaa'))
    }
}
$runCheck = {
    param([string[]]$CheckArgs)
    $data = Join-Path $tmp "gh-$([guid]::NewGuid().ToString('n')).json"
    [System.IO.File]::WriteAllText($data, (ConvertTo-Json -InputObject $gh -Depth 10), $utf8)
    Remove-Item -LiteralPath $ghLog -ErrorAction SilentlyContinue
    $argText = ($CheckArgs | ForEach-Object { if ($_ -cmatch '^-[A-Za-z]+$') { $_ } else { & $quote $_ } }) -join ' '
    $body = $ghStub.Replace('@DATA@', (& $quote $data)).Replace('@LOG@', (& $quote $ghLog)) + "`n& $(& $quote $creditCheck) $argText`nexit `$LASTEXITCODE"
    $r = Invoke-CaseProbe $body
    [pscustomobject]@{ Code = $r.Code; Text = $r.Text; Calls = @(if (Test-Path -LiteralPath $ghLog) { Get-Content -LiteralPath $ghLog }) }
}

$caseRepo = $null
try {
    $caseRepo = New-CaseRepo
    Push-Location -LiteralPath $caseRepo
    try {
        $git = { $out = & git @args 2>&1; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed: $out" } }
        $cfgFile = Join-Path $caseRepo '.github/packet-workflow.json'
        $setCeiling = {
            param($Ceiling)
            $c = Get-Content -Raw -LiteralPath $cfgFile | ConvertFrom-Json -AsHashtable
            $c.budget.maxCreditsPerPacket = $Ceiling
            [System.IO.File]::WriteAllText($cfgFile, ($c | ConvertTo-Json -Depth 10), $utf8)
            & $git add -A; & $git commit -qm "ceiling $Ceiling"; & $git push -q origin main; & $git fetch -q origin
        }
        # No ceiling (the template's null): every command is well formed, prints OFF and calls no gh.
        $offs = foreach ($a in @(, $startArgs) + @(, $fixArgs) + @(, $roundArgs)) { $r = & $runCheck $a; if ($r.Code -ne 0 -or $r.Text -notmatch '^OFF ' -or $r.Calls.Count) { "$($a -join ' '): exit $($r.Code), $($r.Calls.Count) gh calls`n$($r.Text)" } }
        Assert-That (-not $offs) 'with no ceiling, each command as the skills write it prints OFF, exits 0 and calls no gh' ($offs -join "`n")
        & $setCeiling 99999
        $r = & $runCheck $startArgs
        Assert-That ($r.Code -eq 0 -and $r.Text -match '^WITHIN ' -and $r.Calls.Count -eq 0) 'Select''s -Next start, under a ceiling, prints WITHIN before any PR exists' $r.Text
        $r = & $runCheck $roundArgs
        Assert-That ($r.Code -eq 0 -and $r.Text -match '^WITHIN ') 'the panel''s -Next round, after a fix round, prints WITHIN' $r.Text
        $r = & $runCheck $fixArgs
        Assert-That ($r.Code -eq 0 -and $r.Text -match '^WITHIN ') '§8 Fix''s -Next fix after a fix round prints WITHIN' $r.Text
        $ciFixArgs = @($fixArgs | ForEach-Object { if ($_ -eq '21') { '27' } else { $_ } })
        $r = & $runCheck $ciFixArgs
        Assert-That ($r.Code -eq 0 -and $r.Text -match '^WITHIN ') 'a CI fix after a passed round goes through §8 Fix''s check without an error' $r.Text
        $passedStep = [regex]::Match($r.Text, ' step=(\S+) ').Groups[1].Value
        $r = & $runCheck @($fixArgs | ForEach-Object { if ($_ -eq '21') { '28' } else { $_ } })
        $settledStep = [regex]::Match($r.Text, ' step=(\S+) ').Groups[1].Value
        Assert-That ($r.Code -eq 0 -and $r.Text -match '^WITHIN ' -and $passedStep -and $settledStep -eq $passedStep) 'a CI fix after a settled round is priced as after a passed one: the same step (§8)' "passed step=$passedStep`n$($r.Text)"
        & $setCeiling 1
        $r = & $runCheck $startArgs
        Assert-That ($r.Code -eq 3 -and $r.Text -match '^OVER ') 'under a ceiling no packet meets, Select''s check prints OVER and exits 3' $r.Text
        $r = & $runCheck $ciFixArgs
        Assert-That ($r.Code -eq 3 -and $r.Text -match '^OVER so-far=\S+ step=\S+ total=\S+ ceiling=1 ') 'and §8 Fix''s check exits 3 with the so-far, step and ceiling a budget stop quotes' $r.Text
        $r = & $runCheck (@($fixArgs) + @('-Round', '2'))
        Assert-That ($r.Code -ne 0 -and $r.Code -ne 3) 'a call the script can''t take exits neither 0 nor 3, so no step reads it as a pass or a stop' "exit $($r.Code)`n$($r.Text)"

        Write-Host '  the two Needs human first lines'
        $budgetLine = [regex]::Match($budgetStop, '`packet:needs-human reason=budget[^`]*`').Value
        $modelLine = [regex]::Match($modelStop, '`packet:needs-human reason=model-tier[^`]*`').Value
        Assert-That ($budgetLine -ceq '`packet:needs-human reason=budget next=<round|fix> round=<N> so-far=<n> step=<n> ceiling=<n> head=<sha>`') 'the budget stop''s first line is given exactly' $budgetLine
        Assert-That ($modelLine -ceq '`packet:needs-human reason=model-tier agent=<agent> round=<N> head=<sha>`') 'the model-tier stop''s first line is given exactly' $modelLine
        Assert-That ($budgetStop.Contains("``````text`n$budgetLine`n``````") -and $modelStop.Contains("``````text`n$modelLine`n``````") -and $budgetStop.Contains('The comment''s first line is exactly:') -and $modelStop.Contains('The comment''s first line is exactly:')) 'each stands alone as the comment''s first line, in a text block' ''
        $sha = '0123456789abcdef0123456789abcdef01234567'
        $budgetPairs = [ordered]@{ reason = 'budget'; next = 'fix'; round = '1'; 'so-far' = '676'; step = '266'; ceiling = '900'; head = $sha }
        $modelPairs = [ordered]@{ reason = 'model-tier'; agent = 'packet-reviewer-deep'; round = '2'; head = $sha }
        $fillLine = {
            param([string]$Line, $Pairs)
            [regex]::Replace($Line.Trim('`'), '(?<k>[a-z-]+)=<[^>]+>', { param($m) "$($m.Groups['k'].Value)=$($Pairs[$m.Groups['k'].Value])" })
        }
        $budgetMarker = & $fillLine $budgetLine $budgetPairs
        $modelMarker = & $fillLine $modelLine $modelPairs
        $budgetBody = "``$budgetMarker```nThe next fix run would pass this packet's credit ceiling.`n`n> OVER so-far=676 step=266 total=942 ceiling=900 (config)`n"
        $modelBody = "``$modelMarker```nThe host wouldn't start the round's reviewer:`n`n> ``packet-reviewer-deep`` doesn't run: its model exceeds this session's cost tier. Available models: X, Y.`n"
        $budgetFile = Join-Path $tmp 'budget.md'; $modelFile = Join-Path $tmp 'model.md'
        [System.IO.File]::WriteAllText($budgetFile, $budgetBody, $utf8); [System.IO.File]::WriteAllText($modelFile, $modelBody, $utf8)
        $samePairs = {
            param($Got, $Want)
            if ($null -eq $Got) { return $false }
            $names = @($Got.PSObject.Properties.Name | Sort-Object)
            (($names -join ',') -ceq (@($Want.Keys | Sort-Object) -join ',')) -and -not @($Want.Keys | Where-Object { "$($Got.$_)" -cne $Want[$_] })
        }
        foreach ($case in @(@{ Name = 'budget'; File = $budgetFile; Pairs = $budgetPairs }, @{ Name = 'model-tier'; File = $modelFile; Pairs = $modelPairs })) {
            $p = Invoke-CaseProbe "`$m = Get-PwMarker (Get-Content -Raw -LiteralPath $(& $quote $case.File))`n[pscustomobject]@{ Kind = `$m.Kind; Words = @(`$m.Words); Pairs = `$m.Pairs } | ConvertTo-Json -Depth 4 -Compress"
            $j = try { $p.Text | ConvertFrom-Json } catch { $null }
            Assert-That ($p.Code -eq 0 -and $j -and $j.Kind -ceq 'needs-human' -and @($j.Words).Count -eq 0 -and (& $samePairs $j.Pairs $case.Pairs)) "the $($case.Name) first line parses with Get-PwMarker as kind needs-human, with exactly its pairs" $p.Text
        }

        # On the local board: board marker reads each back, the newest first.
        $fails = foreach ($cmd in @(@('setup'), @('sync', '-Phase', 'phase-1'))) { $r = Invoke-Kit $caseBoard $cmd; if ($r.Code -ne 0) { "board $($cmd -join ' '): exit $($r.Code)`n$($r.Text)" } }
        Assert-That (-not $fails) 'the local board syncs the sample phase' ($fails -join "`n")
        $plainFile = Join-Path $tmp 'plain.md'
        [System.IO.File]::WriteAllText($plainFile, "``packet:needs-human```nWhich of these?`n", $utf8)
        $readBack = {
            param([string]$File)
            $c = Invoke-Kit $caseBoard @('comment', 'PKT-03', $File)
            $m = Invoke-Kit $caseBoard @('marker', 'PKT-03', 'needs-human', '-Json')
            [pscustomobject]@{ Code = "$($c.Code)/$($m.Code)"; Text = $m.Text; Json = $(try { $m.Text | ConvertFrom-Json } catch { $null }) }
        }
        [void](& $readBack $plainFile)
        $b = & $readBack $budgetFile
        Assert-That ($b.Code -eq '0/0' -and $b.Json -and $b.Json.Kind -ceq 'needs-human' -and (& $samePairs $b.Json.Pairs $budgetPairs) -and $b.Json.CreatedAt -and $b.Json.Body.StartsWith("``$budgetMarker``")) 'board marker PKT-03 needs-human -Json returns the budget stop''s pairs and when it was posted' $b.Text
        $m = & $readBack $modelFile
        Assert-That ($m.Code -eq '0/0' -and $m.Json -and (& $samePairs $m.Json.Pairs $modelPairs) -and $m.Json.Body.Contains('> `packet-reviewer-deep` doesn''t run')) 'and, posted after it, the model-tier stop''s pairs, with the host''s message in the body' $m.Text
    }
    finally { Pop-Location }
}
finally {
    try { if ($caseRepo) { Remove-CaseRepo $caseRepo } }
    finally { if (-not $Keep) { Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue } }
}

Write-Host '  Needs human: the two stops and their options'
Assert-Phrases $needsHuman @('a blocking finding after the last round (`review.maxRounds`), CI that can''t pass, the credit ceiling, a reviewer the host won''t start') 'Needs human names the last round, the credit ceiling and a refused reviewer'
Assert-Phrases $budgetStop @(
    '`next` is the step that didn''t run. `round` is the round it belongs to'
    '`so-far`, `step` and `ceiling` are the numbers the check printed. `head` is the PR''s head now'
    '1. **Raise:** comment `` `packet:budget max=<credits>` `` on the PR, as the comment''s first words'
    'then `/packet-dispatch resume <ID>`'
    '2. **Pass with follow-ups:** a settle at this head (**Settle**). Offer it only when `next=fix`, `head` is the head of the newest round in `board rounds <pr>`, that round''s outcome is `fix`, and no `settle-check` follows it, so the head is the one the newest round reviewed and its findings are still open. That rules out a CI fix and a fix after the last round.'
    '`` `packet:settle head=<head>` `` as the comment''s only line'
    'Name every blocking finding it would pass'
    '3. **Stop:** close the PR and move the item to Backlog.'
    'With `next=round` there is no option 2: the round was to review a head no panel has seen. Nor is there one for any other `next=fix` stop: a CI fix or an owner''s fix has no open findings to pass.') 'a budget stop offers raise, pass with follow-ups (only at next=fix, naming blocking findings) and stop'
Assert-Phrases $modelStop @(
    'quote the host''s message as it gave it'
    '1. Resume from a dispatcher session on a model at least as dear as the agent''s'
    '2. Resume in the Copilot harness.'
    '3. Give the agent the dispatcher''s class in `models.agents`, merge that, and run the installer again; then resume. This weakens what the agent''s tier means'
    '4. Stop: close the PR and move the item to Backlog.'
    'There is no settle: the head isn''t one a panel reviewed.') 'a model-tier stop quotes the host and offers four ways on, and no settle'
Assert-Phrases $review2 @(
    '**A reviewer the host won''t start stops the round.**'
    'start no other model, no lower tier''s agent, no general-purpose agent and no fewer runs in its place, and post no report'
    'the model-tier stop''s first line (the packet-dispatch skill''s **Needs human**, **A model-tier stop**), quoting the host''s message'
    'Let any run already started finish, and set its answer aside.'
    'Return Needs human.') 'packet-review §2: a refused reviewer stops the round, never a lighter one, and returns Needs human'
Assert-Phrases $review @('and returns Pass, Fix, Needs human, or Stopped when a check fails.', 'stop the round with no report, and return Stopped.', 'say what failed, and return Stopped. Never start a pair on a check that failed.') 'the panel returns Stopped, never a pass, when a check fails'
Assert-Phrases $review2 @('A host that lists a pinned model but refuses to start it for the session''s cost tier is offering it, not withholding it: that is the stop below, not a reason to use the owner''s model or ask for one.') 'packet-review §2: a refused pinned model isn''t one the host withholds'
Assert-Phrases $reviewLimits @('The panel never posts a `packet:budget max=…` or `packet:settle head=…` comment, or raises the ceiling: those are the owner''s.') 'the panel never posts a raise or a settle'
Assert-Phrases $preflight @('A host that refuses a pinned model for its cost tier is offering it, not withholding it', 'That is a model-tier stop (**Needs human**, `reason=model-tier`), when the round reaches it, not a reason to ask the owner for another model.') 'Preflight step 7: a refused pinned model is a model-tier stop, not a question for the owner'
Assert-Phrases $agentSubagents @('A host that refuses a pinned model for that reason is offering it, not withholding it, so don''t ask the owner for another model.', 'the round stops at a model-tier stop (the skill''s **Needs human**, `reason=model-tier`): never run it on another model, a lower tier''s agent or fewer runs.') 'the dispatcher agent''s cost-tier sentence points at the model-tier stop'

Write-Host '  resume after a stop'
Assert-Phrases $resume @('If the marker has `reason=budget` or `reason=model-tier` (its `Pairs`), go to **After a stop** below.') 'Resume sends both stops to After a stop'
$again = ([regex]::Matches($afterStop, [regex]::Escape('with the stop''s own first line again'))).Count
Assert-That ($again -eq 2) 'a refused settle is answered under the stop''s own first line, after a budget stop and after a model-tier stop, so the next resume still reads the stop' "found $again"
Assert-Phrases $afterStop @('Read the PR with `gh pr view <pr> --json state,headRefOid`.') 'after a stop, resume reads the PR''s state and head'
Assert-Phrases $afterStop @('If a raise and a settle that counts are both newer than the stop, the newer of the two decides.') 'a settle that doesn''t count never overrides a raise'
Assert-Phrases $afterStop @('Only an answer newer than the stop counts: a row in `board rounds <pr> -Json` (trusted authors only) whose `CreatedAt` is later than the marker''s.') 'only a trusted answer newer than the stop counts'
# Each way on, and where it ends: another check, or a release.
$paths = [ordered]@{
    'a settle-check already posted'  = @('First, if a trusted `settle-check` newer than the stop follows the newest round, a settle already passed', '`board set <ID> "Status=In review"`, and go to step 9.1.')
    'budget, the PR closed'          = @('- **`reason=budget`**, three ways on:', '**The PR is closed or merged** (the owner chose to stop): release, and stop.')
    'budget, a raise'                = @('**A raise:** a trusted `packet:budget` on the PR (a `budget` row) newer than the stop.', 'carry on at `next=`, where the check runs again: `round` → step 8, the panel, whose own check runs before its first pair; `fix` → step 8, **Fix**, from its credit check, with what the fix was for.')
    'budget, a raise before a CI fix' = @('That is the newest round''s findings only when its outcome is `fix` and no `settle-check` follows it.', 'After a round that passed or was settled, the fix was step 9.3''s CI fix: go to step 9.1, where 9.3 reads CI again and sends a fix back through **Fix**.')
    'budget, a settle'               = @('**A settle:** a `settle-request` row newer than the stop, not `Consumed`. With the rounds used up, it works as **Settle** after the last round.', 'Before the last round it must meet every condition **Settle** sets out there', 'then **Settle**, to pass that round''s findings with follow-ups.')
    'budget, no answer'              = @('Anything else (no answer yet, or a settle that fails one of **Settle**''s conditions): release and stop.')
    'model-tier, the PR closed'      = @('- **`reason=model-tier`:**', '**The PR is closed or merged:** release, and stop.')
    'model-tier, a settle request'   = @('**A settle request** newer than the stop isn''t an answer here', 'and keep it Needs human. Release and stop.')
    'model-tier, a retry'            = @('Otherwise retry the round:', 'The panel runs the round again, from its credit check. If the host refuses the reviewer again, the panel posts the same Needs human.')
}
foreach ($k in $paths.Keys) { Assert-Phrases $afterStop $paths[$k] "after a stop, $k ends in another check or a release" }
Assert-Order $afterStop @('**`reason=budget`**', '**A raise:**', '**A settle:**', 'Anything else', '**`reason=model-tier`:**', 'Otherwise retry the round') 'the budget ways on come before the model-tier ones'
Assert-Phrases $resume @('first, if `board rounds <pr>` lists a `settle-check` newer than the last round, that round was settled (**Settle**): go to step 9.1. Never apply its findings, though its marker says `outcome=fix`') 'an In review packet whose last round was settled goes to step 9.1, never to its findings'
Assert-Phrases $review1 @('After a round that was **settled** (a `settle-check` follows it in `board rounds <pr>`; the packet-dispatch skill''s **Settle**), do the same, `-Confirmed -` and no `-FixedConfirmed`, though its marker says `outcome=fix`') 'the round after a settled one passes -Confirmed - and no -FixedConfirmed'

Write-Host '  the narrow settle'
Assert-Phrases $settle @('**After the last round**, a settle stands in for the round that can''t run', '**Before the last round**, a settle can only pass the newest round''s findings with follow-ups, at the head that round reviewed, and only after a budget stop before a fix', 'The rounds are used up when the newest round''s number in `board rounds <pr>` equals `review.maxRounds`') 'Settle names both cases and when the rounds are used up'
Assert-Phrases $narrow @(
    'Before the last round, a settle counts only when all of these hold'
    '1. the item''s last Needs human (`board marker <ID> needs-human -Json`) is `reason=budget` with `next=fix`, and the request is newer than it;'
    '2. the request''s `head` is the `head` of the newest `round` in `board rounds <pr> -Json`, and the PR''s head now'
    'and the stop''s own `head` and `round` pairs name that head and that round, so the request answers this stop whatever the two clocks say;'
    '3. that round''s outcome is `fix`, and no `settle-check` follows it: its findings are still open;'
    '4. it describes no change: its `Body`, trimmed, is exactly `` `packet:settle head=<that head>` ``, with no other word or pair inside the code span and nothing outside it. Anything more reads as a change, and a change needs a round.'
    'Any other settle before the last round isn''t an answer'
    'never carries a code change'
    'so nothing a panel hasn''t reviewed reaches Ready to merge this way'
    'Nothing is committed or pushed.'
    'Open one follow-up issue per confirmed finding, under packet-review §5''s rules'
    'for a contract finding the title `<ID> contract: <the question>` and the `<labels.needsHuman>` label too'
    'If a label is missing, or opening one fails, stop with no settle-check'
    'A finding an earlier round already filed (packet-review §3, Already filed) isn''t filed again.'
    'A later resume opens only the ones not yet open.') 'a settle before the last round counts only after reason=budget next=fix, at the newest round''s head, with no change, and carries no code'
Assert-Order $narrow @('2. **Follow-ups.**', '3. Check the claim. Comment on the PR: `` `packet:settle-check head=<the request''s head>` ``', '4. `board set <ID> "Status=In review"`, then continue at step 9.1') 'it opens the follow-ups before the settle-check, then goes on to step 9.1'
Assert-Order $dispatch @('### After the last round', 'When the rounds are used up and something still needs a change', '### Before the last round: pass with follow-ups') 'the settle after the last round is kept as it was, ahead of the narrow one'

Write-Host '  the Never lists'
$neverWants = @('Post a comment whose marker is `packet:budget max=…` or `packet:settle head=…`, or raise or change a packet''s credit ceiling')
Assert-Phrases $never ($neverWants + @('The `packet:settle-check` that **Settle** posts stays yours.', 'Run a review round''s reviewer on another model, a lower tier''s agent or fewer runs because the host won''t start it.')) 'the dispatch skill''s Never list forbids packet:budget max=… and packet:settle head=… and raising the ceiling, and leaves packet:settle-check to the dispatcher'
Assert-Phrases $agentNever ($neverWants + @('The `packet:settle-check` that the skill''s **Settle** posts stays yours.')) 'the dispatcher agent''s Never list does the same'

Write-Host '  the last round, not three'
$three = '(?i)\b(three|3)\s+(review\s+)?rounds?\b|\bround\s+(3|three)\b|third round|\brounds\s+1\s*(-|to|–)\s*3\b'
$hits = @(foreach ($f in @(@{ N = 'packet-dispatch/SKILL.md'; T = $dispatch }, @{ N = 'packet-review/SKILL.md'; T = $review }, @{ N = 'round-report-template.md'; T = $template }, @{ N = 'packet-dispatcher.agent.md'; T = $agent })) { foreach ($m in [regex]::Matches($f.T, $three)) { "$($f.N): $($m.Value)" } })
Assert-That ($hits.Count -eq 0) 'no text in the dispatch or review skill, the report template or the dispatcher agent says "three rounds" or "round 3"' ($hits -join "`n")
Assert-Phrases $handOff @('If the last round (`review.maxRounds`) is used, **Needs human**.') '§9.3 stops after the last round (review.maxRounds)'
Assert-Phrases $review @('for at most review.maxRounds rounds') 'the review skill''s description says review.maxRounds rounds'

Write-Host '  the round report''s Credits line'
Assert-That ($template.StartsWith('`packet:round <N> head=<head sha>') -and $template.Contains("`n**Credits** <so far, with this round> of <ceiling> (estimate)`n") -and $template.Contains('<!-- Optional: only when the credit check printed WITHIN; leave it out when it printed OFF. -->')) 'the report template keeps the round marker first and adds an optional Credits line' ''
Assert-Phrases $review4 @('When the credit check (§1) printed `WITHIN`, add the template''s **Credits** line: its `total` (so far, with this round) and its `ceiling`. Leave the line out when it printed `OFF`.') 'packet-review §4 says when the Credits line goes in'
