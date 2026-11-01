# tier-cap.tests.ps1 (PKT-3): review.tierCap in review-scope.ps1 (the cap, the forced reasons, the
# packet's Review tier line, later rounds, Uncapped and Settings.TierCap) and its ModelCheck field.
# Run by tests/run-tests.ps1 in a child scope: plain variables only, never a script-scope one, and kit
# code only through Invoke-Kit and New-CaseRepo (never dot-sourced here).

$capScope = Join-Path $skills 'packet-review/scripts/review-scope.ps1'
$capTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pw-tiercap-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
New-Item -ItemType Directory -Path $capTmp | Out-Null
$capUtf8 = [System.Text.UTF8Encoding]::new($false)

# The template's config with the case repository's settings, a deep and a max path, and one change.
function Get-CapConfig([scriptblock]$Change) {
    $c = Get-Content -Raw (Join-Path $kit 'templates/packet-workflow.json') | ConvertFrom-Json -AsHashtable
    $c.repo = 'example/sample'; $c.board.provider = 'local'
    $c.review.deepPaths = '^src/Deep/'; $c.review.maxPaths = '^src/Max/'
    if ($Change) { & $Change $c }
    $c
}
function Write-CapConfig([string]$Name, $Config) {
    $path = Join-Path $capTmp "$Name.json"
    [System.IO.File]::WriteAllText($path, ($Config | ConvertTo-Json -Depth 10), $capUtf8)
    $path
}
function Write-CapFile([string]$Repo, [string]$Path, [string]$Text) {
    $full = Join-Path $Repo $Path
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
    [System.IO.File]::WriteAllText($full, $Text, $capUtf8)
}
# review-scope -Json, parsed; Json is $null when the output isn't JSON.
function Invoke-CapScope([string[]]$ScopeArgs) {
    $r = Invoke-Kit $capScope (@($ScopeArgs) + '-Json')
    $j = $null; try { $j = $r.Text | ConvertFrom-Json } catch { }
    [pscustomobject]@{ Code = $r.Code; Text = $r.Text; Json = $j }
}
# The fields the cap must leave alone, as one string to compare.
function Get-CapShape($J) {
    $settings = [ordered]@{}; foreach ($p in $J.Settings.PSObject.Properties) { if ($p.Name -ne 'TierCap') { $settings[$p.Name] = $p.Value } }
    [ordered]@{ Tier = $J.Tier; Floor = $J.Floor; Agent = $J.Agent; Reasons = @($J.Reasons); Lenses = @($J.Lenses); Runs = @($J.Runs); Pairs = @($J.Pairs); Settings = $settings } | ConvertTo-Json -Depth 6 -Compress
}

$cfgNull = Write-CapConfig 'null' (Get-CapConfig)
$cfgUnset = Write-CapConfig 'unset' (Get-CapConfig { param($c) $c.review.Remove('tierCap') })
$cfgThree = Write-CapConfig 'three' (Get-CapConfig { param($c) $c.review.tierCap = 3 })
$cfgTwo = Write-CapConfig 'two' (Get-CapConfig { param($c) $c.review.tierCap = 2 })

$capRepo = New-CaseRepo
Push-Location -LiteralPath $capRepo
try {
    # A packet whose Review tier line is 3, on main, so it is there at the base.
    $pk11 = (Get-Content -Raw (Join-Path $capRepo 'docs/plan/phase-1/packets/PKT-03.md')) -replace 'PKT-03', 'PKT-11' -replace 'Api endpoints', 'Deep docs' -replace '- \*\*Locks:\*\* none', "- **Locks:** none`n- **Review tier:** 3" -replace '`src/Api/\*\*`', '`docs/deep/**`'
    Write-CapFile $capRepo 'docs/plan/phase-1/packets/PKT-11.md' $pk11
    & git add -A; & git commit -qm 'PKT-11' | Out-Null; & git push -q origin main 2>$null; & git fetch -q origin

    # The diffs, one commit each on a branch, each read as HEAD~1...HEAD (or main... for the whole branch).
    & git switch -q -c case/cap
    Write-CapFile $capRepo 'src/Api/Orders.cs' (("public class Orders {`n" + (1..20 | ForEach-Object { "  public int M$_(int x) { if (x > $_) { return x; } return 0; }`n" }) + "}`n") -join '')
    Write-CapFile $capRepo 'src/Api/Auth/TokenCheck.cs' "class TokenCheck { static readonly SemaphoreSlim Gate = new(1); }`n"
    & git add -A; & git commit -qm 'the auth-path-and-semaphore diff' | Out-Null
    $apiSha = (& git rev-parse HEAD).Trim()
    Write-CapFile $capRepo 'src/Api/Big.cs' (((1..412) | ForEach-Object { "// line $_" }) -join "`n") + "`n"
    & git add -A; & git commit -qm '412 lines in one subsystem' | Out-Null
    $bigSha = (& git rev-parse HEAD).Trim()
    Write-CapFile $capRepo 'docs/notes.md' "a note`n"
    & git add -A; & git commit -qm 'a docs diff' | Out-Null
    $docsSha = (& git rev-parse HEAD).Trim()
    Write-CapFile $capRepo 'src/Api/Svc.cs' "class Svc {`n  async Task Run() { await Task.Delay(10); }`n}`n"
    & git add -A; & git commit -qm 'async' | Out-Null
    $asyncSha = (& git rev-parse HEAD).Trim()

    Write-Host '  no cap: unset, null or 3'
    $diffs = [ordered]@{
        'the auth-path-and-semaphore diff (PKT-03)' = @('-Base', 'main', '-Head', $apiSha, '-Packet', 'PKT-03')
        'the 412-line diff' = @('-Base', "$bigSha~1", '-Head', $bigSha)
        'the docs diff' = @('-Base', "$docsSha~1", '-Head', $docsSha)
        'the docs diff after a fixed tier-1 round' = @('-Base', "$docsSha~1", '-Head', $docsSha, '-PreviousTier', '1', '-FixedConfirmed')
        'the docs diff after a fixed tier-2 round' = @('-Base', "$docsSha~1", '-Head', $docsSha, '-PreviousTier', '2', '-FixedConfirmed')
        'the async diff' = @('-Base', "$asyncSha~1", '-Head', $asyncSha)
        'round 2 of the whole branch' = @('-Base', 'main', '-Packet', 'PKT-03', '-Since', $apiSha, '-Confirmed', 'security', '-PreviousTier', '3', '-FixedConfirmed')
    }
    foreach ($name in $diffs.Keys) {
        $u = Invoke-CapScope ($diffs[$name] + @('-ConfigPath', $cfgUnset))
        $n = Invoke-CapScope ($diffs[$name] + @('-ConfigPath', $cfgNull))
        $t = Invoke-CapScope ($diffs[$name] + @('-ConfigPath', $cfgThree))
        $ok = $u.Code -eq 0 -and $n.Code -eq 0 -and $t.Code -eq 0 -and $u.Json -and $n.Json -and $t.Json
        $ok = $ok -and (Get-CapShape $u.Json) -ceq (Get-CapShape $n.Json) -and (Get-CapShape $u.Json) -ceq (Get-CapShape $t.Json)
        $ok = $ok -and @($u.Json, $n.Json, $t.Json | Where-Object { $_.Uncapped -ne $_.Floor }).Count -eq 0
        $ok = $ok -and $null -eq $u.Json.Settings.TierCap -and $null -eq $n.Json.Settings.TierCap -and $t.Json.Settings.TierCap -eq 3
        $ok = $ok -and -not ($u.Json.Reasons, $n.Json.Reasons, $t.Json.Reasons | Where-Object { $_ -match 'tierCap' })
        Assert-That $ok "$($name): tierCap unset, null and 3 give the same Tier, Floor, Agent, Reasons, Lenses, Runs, Pairs and Settings, Uncapped = Floor" "$($u.Text)`n---`n$($n.Text)`n---`n$($t.Text)"
        $names = @($u.Json.PSObject.Properties.Name)
        $settingNames = @($u.Json.Settings.PSObject.Properties.Name)
        Assert-That (($names -join ',') -ceq 'Tier,Name,Agent,Floor,Uncapped,Base,Head,HeadSha,BaseSha,Files,Lines,Breakdown,Reasons,Lenses,LensReasons,Runs,Pairs,Settings,ModelCheck' -and ($settingNames -join ',') -ceq 'MaxRounds,ShouldFixPassFromRound,MaxParallelLenses,LensesPerReviewer,TierCap' -and (@($u.Json.ModelCheck.PSObject.Properties.Name) -join ',') -ceq 'Agent,AgentClass,DispatcherClass,Warning') "$($name): the only new fields are Uncapped, Settings.TierCap and ModelCheck" ($names -join ',')
    }
    $a = Invoke-Kit $capScope @('-Base', 'main', '-Head', $apiSha, '-Packet', 'PKT-03', '-ConfigPath', $cfgUnset)
    $b = Invoke-Kit $capScope @('-Base', 'main', '-Head', $apiSha, '-Packet', 'PKT-03', '-ConfigPath', $cfgNull)
    Assert-That ($a.Code -eq 0 -and $a.Text -ceq $b.Text -and $a.Text -notmatch 'UNCAPPED|tier cap|MODEL CHECK' -and ($a.Text -split "`n")[0] -cmatch '^TIER=3 \(deep\) AGENT=packet-reviewer-deep FLOOR=3$') 'with no cap the text output has no UNCAPPED, tier cap or MODEL CHECK, and unset and null print the same' "$($a.Text)`n---`n$($b.Text)"

    Write-Host '  tierCap 2'
    $r = Invoke-CapScope @('-Base', "$bigSha~1", '-Head', $bigSha, '-ConfigPath', $cfgTwo)
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 2 -and $r.Json.Floor -eq 2 -and $r.Json.Uncapped -eq 3 -and $r.Json.Agent -eq 'packet-reviewer-standard' -and $r.Json.Settings.TierCap -eq 2 -and $r.Json.Lines -eq 412 -and @($r.Json.Reasons) -ccontains 'capped at 2 by review.tierCap: 412 lines > 300') 'a 412-line code diff in one subsystem is tier 2, Floor 2, Uncapped 3, on the standard reviewer' $r.Text
    $t = Invoke-Kit $capScope @('-Base', "$bigSha~1", '-Head', $bigSha, '-ConfigPath', $cfgTwo)
    $lines = $t.Text -split "`n"
    Assert-That ($t.Code -eq 0 -and $lines[0] -ceq 'TIER=2 (standard) AGENT=packet-reviewer-standard FLOOR=2 UNCAPPED=3 (review.tierCap 2)' -and $t.Text -match '(?m)^SETTINGS=.*, tier cap 2$') 'the text output''s first line adds UNCAPPED=3 (review.tierCap 2)' $t.Text
    $r = Invoke-CapScope @('-Base', 'main', '-Head', $apiSha, '-Packet', 'PKT-03', '-ConfigPath', $cfgTwo)
    $why = @($r.Json.Reasons)
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 2 -and $r.Json.Floor -eq 2 -and $r.Json.Uncapped -eq 3 -and $r.Json.Agent -eq 'packet-reviewer-standard' -and ($why | Where-Object { $_ -cmatch '^capped at 2 by review\.tierCap: auth/security path: src/Api/Auth/' }) -and (@($r.Json.Lenses) -join ',') -ceq 'security,concurrency,correctness') 'the auth-path-and-semaphore diff (PKT-03) is tier 2, its auth raise says capped, and its lenses stay' $r.Text
    $r = Invoke-CapScope @('-Base', "$asyncSha~1", '-Head', $asyncSha, '-ConfigPath', $cfgTwo)
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 2 -and $r.Json.Uncapped -eq 3 -and (@($r.Json.Reasons) | Where-Object { $_ -cmatch '^capped at 2 by review\.tierCap: concurrency in added lines' })) 'concurrency in added lines is capped' $r.Text
    $r = Invoke-CapScope @('-Base', "$docsSha~1", '-Head', $docsSha, '-ConfigPath', $cfgTwo)
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 1 -and $r.Json.Floor -eq 1 -and $r.Json.Uncapped -eq 1 -and -not (@($r.Json.Reasons) | Where-Object { $_ -match 'tierCap' })) 'a diff below the cap is untouched' $r.Text

    Write-Host '  tierCap 2: the forced reasons'
    $forced = [ordered]@{
        'a review.deepPaths match' = @{ Path = 'src/Deep/Thing.cs'; Text = "class Thing {}`n"; Why = 'project deep path' }
        'a review.maxPaths match' = @{ Path = 'src/Max/Thing.cs'; Text = "class Thing {}`n"; Why = 'project critical path' }
        'a .github/skills change' = @{ Path = '.github/skills/x/SKILL.md'; Text = "x`n"; Why = 'review machinery' }
        'a .github/agents change' = @{ Path = '.github/agents/x.agent.md'; Text = "x`n"; Why = 'review machinery' }
        'a .github/hooks change' = @{ Path = '.github/hooks/x.json'; Text = "{}`n"; Why = 'review machinery' }
        'a .github/workflows change' = @{ Path = '.github/workflows/ci.yml'; Text = "on: push`n"; Why = 'review machinery' }
        'a project lens folder change' = @{ Path = '.github/packet-lenses/data.md'; Text = "# Lens`n"; Why = 'review machinery' }
        'a .github/packet-workflow.json change' = @{ Path = '.github/packet-workflow.json'; Text = $null; Why = 'review machinery' }
        'a .gitattributes change' = @{ Path = '.gitattributes'; Text = "* text=auto`n"; Why = 'attributes file changed' }
        'a lockfile-only diff' = @{ Path = 'package-lock.json'; Text = "{}`n"; Why = 'only ignored files' }
    }
    foreach ($name in $forced.Keys) {
        $f = $forced[$name]
        $text = if ($null -ne $f.Text) { $f.Text } else { (Get-Content -Raw (Join-Path $capRepo $f.Path)) + "`n" }
        Write-CapFile $capRepo $f.Path $text
        & git add -A; & git commit -qm $name | Out-Null
        $r = Invoke-CapScope @('-Base', 'HEAD~1', '-ConfigPath', $cfgTwo)
        Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 3 -and $r.Json.Floor -eq 3 -and $r.Json.Uncapped -eq 3 -and $r.Json.Agent -eq 'packet-reviewer-deep' -and (@($r.Json.Reasons) | Where-Object { $_ -match [regex]::Escape($f.Why) -and $_ -notmatch 'tierCap' })) "$name is tier 3 under tierCap 2" $r.Text
        & git reset -q --hard HEAD~1
    }
    # A forced reason beside a capped one: the tier is 3, and nothing was capped.
    Write-CapFile $capRepo 'src/Deep/Big.cs' (((1..400) | ForEach-Object { "// line $_" }) -join "`n") + "`n"
    & git add -A; & git commit -qm 'deep and big' | Out-Null
    $r = Invoke-CapScope @('-Base', 'HEAD~1', '-ConfigPath', $cfgTwo)
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 3 -and $r.Json.Uncapped -eq 3 -and -not (@($r.Json.Reasons) | Where-Object { $_ -match 'tierCap' }) -and (@($r.Json.Reasons) -ccontains '400 lines > 300')) 'with a forced reason, the size raise stands and no reason says capped' $r.Text
    & git reset -q --hard HEAD~1
    # The packet's Review tier line still raises past the cap.
    Write-CapFile $capRepo 'docs/deep/notes.md' "a note`n"
    & git add -A; & git commit -qm 'deep docs' | Out-Null
    $r = Invoke-CapScope @('-Base', 'HEAD~1', '-Packet', 'PKT-11', '-ConfigPath', $cfgTwo)
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 3 -and $r.Json.Floor -eq 1 -and $r.Json.Agent -eq 'packet-reviewer-deep' -and (@($r.Json.Reasons) -join ' ') -match "raised to 3 by PKT-11's Review tier line") 'a packet whose Review tier line is 3 is tier 3 under tierCap 2' $r.Text
    Write-CapFile $capRepo 'src/Api/Big2.cs' (((1..412) | ForEach-Object { "// line $_" }) -join "`n") + "`n"
    & git add -A; & git commit -qm 'big, under the Review tier line' | Out-Null
    $r = Invoke-CapScope @('-Base', 'HEAD~1', '-Packet', 'PKT-11', '-ConfigPath', $cfgTwo)
    $t = Invoke-Kit $capScope @('-Base', 'HEAD~1', '-Packet', 'PKT-11', '-ConfigPath', $cfgTwo)
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 3 -and $r.Json.Floor -eq 2 -and $r.Json.Uncapped -eq 3 -and ($t.Text -split "`n")[0] -ceq 'TIER=3 (deep) AGENT=packet-reviewer-deep FLOOR=2 UNCAPPED=3 (review.tierCap 2)') 'with the Review tier line over a capped diff: Tier 3, Floor 2, Uncapped 3' "$($r.Text)`n$($t.Text)"
    & git reset -q --hard HEAD~2

    Write-Host '  tierCap 2: later rounds'
    $r = Invoke-CapScope @('-Base', "$docsSha~1", '-Head', $docsSha, '-PreviousTier', '2', '-FixedConfirmed', '-ConfigPath', $cfgTwo)
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 2 -and $r.Json.Agent -eq 'packet-reviewer-standard' -and (@($r.Json.Reasons) -ccontains 'capped at 2 by review.tierCap: the previous round ran at 2, and its confirmed findings were fixed (+1)')) '-PreviousTier 2 -FixedConfirmed stays 2, and says the +1 was capped' $r.Text
    $r = Invoke-CapScope @('-Base', "$docsSha~1", '-Head', $docsSha, '-PreviousTier', '3', '-ConfigPath', $cfgTwo)
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 3 -and $r.Json.Agent -eq 'packet-reviewer-deep' -and (@($r.Json.Reasons) -ccontains 'raised to 3: the previous round ran at 3')) '-PreviousTier 3 with no forced reason left stays 3' $r.Text
    $r = Invoke-CapScope @('-Base', "$docsSha~1", '-Head', $docsSha, '-PreviousTier', '3', '-FixedConfirmed', '-ConfigPath', $cfgTwo)
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 3) '-PreviousTier 3 -FixedConfirmed stays 3' $r.Text
    $r = Invoke-CapScope @('-Base', "$docsSha~1", '-Head', $docsSha, '-PreviousTier', '4', '-ConfigPath', $cfgTwo)
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 3) '-PreviousTier 4 (before tiers 3 and 4 merged) stays 3' $r.Text
    $r = Invoke-CapScope @('-Base', "$docsSha~1", '-Head', $docsSha, '-PreviousTier', '1', '-FixedConfirmed', '-ConfigPath', $cfgTwo)
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 2 -and -not (@($r.Json.Reasons) | Where-Object { $_ -match 'tierCap' })) '-PreviousTier 1 -FixedConfirmed still goes up to 2' $r.Text
    $r = Invoke-CapScope @('-Base', 'main', '-Packet', 'PKT-03', '-Since', $apiSha, '-Confirmed', 'security', '-PreviousTier', '2', '-FixedConfirmed', '-ConfigPath', $cfgTwo)
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 2 -and $r.Json.Uncapped -eq 3) 'round 2 of the PKT-03 branch after a fixed tier-2 round stays 2' $r.Text
    Write-CapFile $capRepo 'src/Deep/Thing.cs' "class Thing {}`n"
    & git add -A; & git commit -qm 'deep' | Out-Null
    $r = Invoke-CapScope @('-Base', 'HEAD~1', '-PreviousTier', '2', '-FixedConfirmed', '-ConfigPath', $cfgTwo)
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 3 -and -not (@($r.Json.Reasons) | Where-Object { $_ -match 'tierCap' })) 'with a forced reason the +1 is not capped' $r.Text
    & git reset -q --hard HEAD~1

    Write-Host '  tierCap from the base'
    $cfgFile = Join-Path $capRepo '.github/packet-workflow.json'
    $baseCfg = Get-Content -Raw $cfgFile | ConvertFrom-Json -AsHashtable
    $baseCfg.review.tierCap = 2
    Write-CapFile $capRepo '.github/packet-workflow.json' ($baseCfg | ConvertTo-Json -Depth 10)
    Write-CapFile $capRepo 'src/Api/Big3.cs' (((1..412) | ForEach-Object { "// line $_" }) -join "`n") + "`n"
    & git add -A; & git commit -qm 'a branch that sets tierCap 2' | Out-Null
    $r = Invoke-CapScope @('-Base', 'HEAD~1')
    Assert-That ($r.Code -eq 0 -and $null -eq $r.Json.Settings.TierCap -and $r.Json.Tier -eq 3 -and $r.Json.Uncapped -eq 3 -and (@($r.Json.Reasons) | Where-Object { $_ -match 'review machinery path: \.github/packet-workflow\.json' }) -and -not (@($r.Json.Reasons) | Where-Object { $_ -match 'tierCap' })) 'a branch that sets tierCap 2 over a base without one gets no cap, and tier 3 (machinery)' $r.Text
    $capBase = (& git rev-parse HEAD).Trim()
    & git rm -q --cached src/Api/Big3.cs; Remove-Item -LiteralPath (Join-Path $capRepo 'src/Api/Big3.cs')
    Write-CapFile $capRepo 'src/Api/Big4.cs' (((1..412) | ForEach-Object { "// other line $_" }) -join "`n") + "`n"
    & git add -A; & git commit -qm 'over a base with tierCap 2' | Out-Null
    $r = Invoke-CapScope @('-Base', $capBase)
    Assert-That ($r.Code -eq 0 -and $r.Json.Settings.TierCap -eq 2 -and $r.Json.Tier -eq 2 -and $r.Json.Uncapped -eq 3) 'Settings.TierCap reports the base''s 2, and the base''s cap applies' $r.Text
    $baseCfg.review.tierCap = $null
    Write-CapFile $capRepo '.github/packet-workflow.json' ($baseCfg | ConvertTo-Json -Depth 10)
    & git add -A; & git commit -qm 'a branch that drops the cap' | Out-Null
    $r = Invoke-CapScope @('-Base', $capBase)
    Assert-That ($r.Code -eq 0 -and $r.Json.Settings.TierCap -eq 2 -and $r.Json.Tier -eq 3 -and (@($r.Json.Reasons) | Where-Object { $_ -match 'review machinery' })) 'a branch that drops the base''s cap still reads TierCap 2 (and its config edit is machinery)' $r.Text
    & git reset -q --hard HEAD~3

    Write-Host '  tierCap the config check refuses'
    $r = Invoke-Kit $capScope @('-Base', "$bigSha~1", '-Head', $bigSha, '-Json', '-ConfigPath', (Write-CapConfig 'one' (Get-CapConfig { param($c) $c.review.tierCap = 1 })))
    Assert-That ($r.Code -eq 2 -and $r.Text -match 'review\.tierCap must be 2 or 3') 'tierCap 1 makes review-scope exit 2' $r.Text

    Write-Host '  ModelCheck'
    $split = { param($c) $c.models.strong = @('Model S (copilot)'); $c.models.standard = @('Model M (copilot)'); $c.models.agents = @{ 'packet-dispatcher' = 'standard' } }
    $cfgSplit = Write-CapConfig 'split' (Get-CapConfig $split)
    $r = Invoke-CapScope @('-Base', 'main', '-Head', $apiSha, '-Packet', 'PKT-03', '-ConfigPath', $cfgSplit)
    $w = "$($r.Json.ModelCheck.Warning)"
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 3 -and $r.Json.ModelCheck.Agent -eq 'packet-reviewer-deep' -and $r.Json.ModelCheck.AgentClass -eq 'strong' -and $r.Json.ModelCheck.DispatcherClass -eq 'standard' -and $w -match 'packet-reviewer-deep' -and $w -match '\bstrong\b' -and $w -match '\bstandard\b' -and $w -match 'Local harness' -and $w -match 'Model S' -and $w -match 'Model M') 'ModelCheck.Warning names packet-reviewer-deep, both classes and the Local harness on a tier-3 round with the dispatcher on standard' $r.Text
    $t = Invoke-Kit $capScope @('-Base', 'main', '-Head', $apiSha, '-Packet', 'PKT-03', '-ConfigPath', $cfgSplit)
    Assert-That ($t.Code -eq 0 -and $t.Text -match '(?m)^MODEL CHECK: packet-reviewer-deep runs on the strong class') 'the text output prints the warning' $t.Text
    $r = Invoke-CapScope @('-Base', "$bigSha~1", '-Head', $bigSha, '-ConfigPath', (Write-CapConfig 'split-two' (Get-CapConfig { param($c) & $split $c; $c.review.tierCap = 2 })))
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 2 -and $r.Json.ModelCheck.Agent -eq 'packet-reviewer-standard' -and $r.Json.ModelCheck.AgentClass -eq 'standard' -and $null -eq $r.Json.ModelCheck.Warning) 'a capped round on the standard reviewer has no warning' $r.Text
    $r = Invoke-CapScope @('-Base', 'main', '-Head', $apiSha, '-Packet', 'PKT-03', '-ConfigPath', (Write-CapConfig 'same' (Get-CapConfig { param($c) $c.models.agents = @{ 'packet-dispatcher' = 'standard' } })))
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 3 -and $r.Json.ModelCheck.AgentClass -eq 'strong' -and $r.Json.ModelCheck.DispatcherClass -eq 'standard' -and $null -eq $r.Json.ModelCheck.Warning) 'with the template''s identical lists the warning is null' $r.Text
    $r = Invoke-CapScope @('-Base', 'main', '-Head', $apiSha, '-Packet', 'PKT-03', '-ConfigPath', $cfgNull)
    Assert-That ($r.Code -eq 0 -and $r.Json.ModelCheck.AgentClass -eq 'strong' -and $r.Json.ModelCheck.DispatcherClass -eq 'strong' -and $null -eq $r.Json.ModelCheck.Warning) 'with the kit''s classes the dispatcher and the deep reviewer are both strong: no warning' $r.Text
    $r = Invoke-CapScope @('-Base', 'main', '-Head', $apiSha, '-Packet', 'PKT-03', '-ConfigPath', (Write-CapConfig 'own' (Get-CapConfig { param($c) & $split $c; $c.review.agents = @{ '1' = 'packet-reviewer-light'; '2' = 'packet-reviewer-standard'; '3' = 'my-deep' } })))
    Assert-That ($r.Code -eq 0 -and $r.Json.ModelCheck.Agent -eq 'my-deep' -and $null -eq $r.Json.ModelCheck.AgentClass -and $null -eq $r.Json.ModelCheck.Warning) 'an agent the kit doesn''t ship has no class and no warning' $r.Text
    $r = Invoke-CapScope @('-Base', 'main', '-Head', $apiSha, '-Packet', 'PKT-03', '-ConfigPath', (Write-CapConfig 'badclass' (Get-CapConfig { param($c) $c.models.agents = @{ 'packet-dispatcher' = 'premium' } })))
    Assert-That ($r.Code -eq 0 -and $r.Json.Tier -eq 3 -and "$($r.Json.ModelCheck.Warning)" -match "models\.agents\.packet-dispatcher must be strong, standard or light \(got 'premium'\)") 'a models.agents entry naming an unknown class: exit 0, and Warning holds the error' $r.Text
    $r = Invoke-CapScope @('-Base', 'main', '-Head', $apiSha, '-Packet', 'PKT-03', '-ConfigPath', (Write-CapConfig 'badagent' (Get-CapConfig { param($c) $c.models.agents = @{ 'packet-reviewer-max' = 'strong' } })))
    Assert-That ($r.Code -eq 0 -and "$($r.Json.ModelCheck.Warning)" -match "models\.agents\.packet-reviewer-max is not one of the kit's agents") 'a models.agents entry naming an agent the kit doesn''t ship: exit 0, and Warning holds the error' $r.Text
}
finally {
    Pop-Location
    Remove-CaseRepo $capRepo
    if (-not $Keep) { Remove-Item -Recurse -Force -LiteralPath $capTmp -ErrorAction SilentlyContinue }
}
