# config-keys.tests.ps1 (PKT-1): review.tierCap, budget.maxCreditsPerPacket, models.agents, the kit's
# lens list, and the case-file runner with its New-CaseRepo, Remove-CaseRepo and Invoke-CaseProbe helpers.
# Run by tests/run-tests.ps1 in a child scope: plain variables only, never a script-scope one, and kit
# code only through Invoke-CaseProbe (never dot-sourced here).

$caseBoard = Join-Path $skills 'packet-board/scripts/board.ps1'
$caseScope = Join-Path $skills 'packet-review/scripts/review-scope.ps1'
$caseProgress = Join-Path $skills 'packet-progress/scripts/progress.ps1'
$runner = Join-Path $kit 'tests/run-tests.ps1'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pw-cfgkeys-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
$utf8 = [System.Text.UTF8Encoding]::new($false)
# The template's config, as a fresh hashtable to change one key in and write out.
function Get-TemplateConfig {
    $c = Get-Content -Raw (Join-Path $kit 'templates/packet-workflow.json') | ConvertFrom-Json -AsHashtable
    $c.repo = 'example/sample'; $c.board.provider = 'local'
    $c
}
function Write-Config([string]$Name, $Config) {
    $path = Join-Path $tmp "$Name.json"
    [System.IO.File]::WriteAllText($path, ($Config | ConvertTo-Json -Depth 10), $utf8)
    $path
}

$before = (Get-Location).Path
$caseRepo = New-CaseRepo
try {
    Write-Host '  New-CaseRepo'
    Assert-That ((Get-Location).Path -eq $before) 'New-CaseRepo leaves the current directory as it found it' "before $before, after $((Get-Location).Path)"
    $originHead = (& git -C $caseRepo symbolic-ref refs/remotes/origin/HEAD 2>&1) -join ''
    $caseCfg = Get-Content -Raw (Join-Path $caseRepo '.github/packet-workflow.json') | ConvertFrom-Json -AsHashtable
    Assert-That ($originHead -eq 'refs/remotes/origin/main' -and $caseCfg.repo -eq 'example/sample' -and $caseCfg.board.provider -eq 'local' -and (Test-Path (Join-Path $caseRepo 'docs/plan/phase-1/packets/PKT-03.md'))) 'it has the sample phase, the local board, repo set, and origin/HEAD at main' "origin/HEAD: $originHead"
    Push-Location -LiteralPath $caseRepo
    try {
        $r = Invoke-Kit $caseBoard @('show')
        Assert-That ($r.Code -eq 0 -and $r.Text -match 'board: local') 'board show exits 0 in a New-CaseRepo repository' $r.Text
        $r = Invoke-Kit $caseProgress @('-Json')
        $ok = $r.Code -eq 0; try { [void]($r.Text | ConvertFrom-Json) } catch { $ok = $false }
        Assert-That $ok 'progress.ps1 -Json exits 0 there with JSON' $r.Text

        Write-Host '  review.tierCap'
        # A diff for review-scope to read: one file under the packet's Owns.
        & git switch -q -c case/tier-cap
        [System.IO.File]::WriteAllText((Join-Path $caseRepo 'src/Api/Orders.cs'), "class Orders { int M(int x) { if (x > 1) { return x; } return 0; } }`n", $utf8)
        & git add -A; & git commit -qm 'orders' | Out-Null
        foreach ($case in @(@{ Name = 'null'; Value = $null; Want = '<null>' }, @{ Name = '2'; Value = 2; Want = 'Int32:2' }, @{ Name = '3'; Value = 3; Want = 'Int32:3' }, @{ Name = '"2"'; Value = '2'; Want = 'Int32:2' })) {
            $c = Get-TemplateConfig; $c.review.tierCap = $case.Value
            $path = Write-Config "tiercap-ok-$($case.Want -replace '\W', '')" $c
            $r = Invoke-Kit $caseScope @('-Base', 'main', '-Packet', 'PKT-03', '-Json', '-ConfigPath', $path)
            $p = Invoke-CaseProbe "`$c = Get-PwConfig -Path '$path'; if (`$null -eq `$c.review.tierCap) { '<null>' } else { `"`$(`$c.review.tierCap.GetType().Name):`$(`$c.review.tierCap)`" }"
            Assert-That ($r.Code -eq 0 -and $p.Code -eq 0 -and $p.Text.Trim() -eq $case.Want) "tierCap $($case.Name) loads, and Get-PwConfig gives $($case.Want)" "$($r.Text)`n$($p.Text)"
        }
        foreach ($case in @(@{ Name = '0'; Value = 0 }, @{ Name = '1'; Value = 1 }, @{ Name = '4'; Value = 4 }, @{ Name = '2.5'; Value = 2.5 }, @{ Name = '"two"'; Value = 'two' }, @{ Name = 'true'; Value = $true }, @{ Name = '3000000000'; Value = [long]3000000000 })) {
            $c = Get-TemplateConfig; $c.review.tierCap = $case.Value
            $path = Write-Config "tiercap-bad-$($case.Name -replace '\W', '')" $c
            $r = Invoke-Kit $caseScope @('-Base', 'main', '-Packet', 'PKT-03', '-Json', '-ConfigPath', $path)
            Assert-That ($r.Code -eq 2 -and $r.Text -match 'config: review\.tierCap must be 2 or 3, or null for no cap \(got ') "tierCap $($case.Name) makes review-scope exit 2, naming review.tierCap" $r.Text
        }
        $p = Invoke-CaseProbe "`$c = Get-PwConfig -Path '$(Write-Config 'tiercap-quoted' ((Get-TemplateConfig) | ForEach-Object { $_.review.tierCap = '3'; $_ }))'; `"cfg=`$(`$c.review.tierCap)|defaults=`$(`$null -eq `$script:Defaults.review.tierCap)`""
        Assert-That ($p.Text.Trim() -eq 'cfg=3|defaults=True') 'Get-PwConfig fills tierCap on its copy, not on the shared defaults' $p.Text
        # Nothing new for an install that sets none of the keys: the template's nulls, and a 0.1.1 config
        # without the keys at all, give review-scope the same JSON.
        $old = Get-TemplateConfig; $old.review.Remove('tierCap'); $old.budget.Remove('maxCreditsPerPacket'); $old.models.Remove('agents')
        $a = Invoke-Kit $caseScope @('-Base', 'main', '-Packet', 'PKT-03', '-Json', '-ConfigPath', (Write-Config 'new-keys' (Get-TemplateConfig)))
        $b = Invoke-Kit $caseScope @('-Base', 'main', '-Packet', 'PKT-03', '-Json', '-ConfigPath', (Write-Config 'old-keys' $old))
        Assert-That ($a.Code -eq 0 -and $b.Code -eq 0 -and $a.Text -ceq $b.Text) 'review-scope''s JSON is the same with the new keys at their defaults and without them' "$($a.Text)`n---`n$($b.Text)"
        & git switch -q main

        Write-Host '  budget.maxCreditsPerPacket'
        $p = Invoke-CaseProbe @'
function Ceiling([string]$Json) {
    $c = Merge-PwHashtable $script:Defaults ($Json | ConvertFrom-Json -AsHashtable)
    (@('S', 'M', 'L') | ForEach-Object {
        $size = $_
        try { $v = Get-PwCreditCeiling -Config $c -Size $size; "$size=$(if ($null -eq $v) { '<null>' } else { "$($v.GetType().Name):$v" })" }
        catch [PwError] { "$size=err:$($_.Exception.Message)" }
    }) -join '|'
}
"unset  $(Ceiling '{}')"
"null   $(Ceiling '{ "budget": { "maxCreditsPerPacket": null } }')"
"flat   $(Ceiling '{ "budget": { "maxCreditsPerPacket": 1500 } }')"
"table  $(Ceiling '{ "budget": { "maxCreditsPerPacket": { "S": 900, "M": 1300, "L": 2000 } } }')"
"onlyS  $(Ceiling '{ "budget": { "maxCreditsPerPacket": { "S": 900 } } }')"
"zero   $(Ceiling '{ "budget": { "maxCreditsPerPacket": 0 } }')"
"neg    $(Ceiling '{ "budget": { "maxCreditsPerPacket": -5 } }')"
"string $(Ceiling '{ "budget": { "maxCreditsPerPacket": "lots" } }')"
"bool   $(Ceiling '{ "budget": { "maxCreditsPerPacket": true } }')"
"quoted $(Ceiling '{ "budget": { "maxCreditsPerPacket": "1500" } }')"
"lower  $(Ceiling '{ "budget": { "maxCreditsPerPacket": { "s": 900, "m": 1300, "l": 2000 } } }')"
"list   $(Ceiling '{ "budget": { "maxCreditsPerPacket": { "S": [900], "M": [1300], "L": [2000] } } }')"
"dup    $(Ceiling '{ "budget": { "maxCreditsPerPacket": { "M": 1300, "m": 900, "S": 1, "L": 1 } } }')"
$c = Merge-PwHashtable $script:Defaults ('{ "budget": { "maxCreditsPerPacket": { "S": 900, "M": 1300, "L": 2000 } } }' | ConvertFrom-Json -AsHashtable)
"lowsize $(try { Get-PwCreditCeiling -Config $c -Size m } catch [PwError] { "err:$($_.Exception.Message)" })"
'@
        $rows = @{}; foreach ($line in ($p.Text -split "`n")) { if ($line -match '^(\w+)\s+(.*)$') { $rows[$Matches[1]] = $Matches[2] } }
        $named = 'err:config: budget\.maxCreditsPerPacket must be a positive number'
        Assert-That ($rows['unset'] -eq 'S=<null>|M=<null>|L=<null>' -and $rows['null'] -eq 'S=<null>|M=<null>|L=<null>') 'Get-PwCreditCeiling: unset (or null) gives $null for every size' $p.Text
        Assert-That ($rows['flat'] -eq 'S=Double:1500|M=Double:1500|L=Double:1500') '1500 gives 1500 for S, M and L' $p.Text
        Assert-That ($rows['table'] -eq 'S=Double:900|M=Double:1300|L=Double:2000') '{ S: 900, M: 1300, L: 2000 } gives 1300 for M (and each size its own)' $p.Text
        Assert-That ($rows['onlyS'] -match '^S=Double:900\|M=' -and ($rows['onlyS'] -split '\|')[1] -match "^M=$named") '{ S: 900 } throws for M, naming budget.maxCreditsPerPacket' $p.Text
        Assert-That ($rows['lower'] -eq 'S=Double:900|M=Double:1300|L=Double:2000' -and $rows['lowsize'] -eq '1300') 'a size table is read with the size''s case folded, as the other size tables are' $p.Text
        Assert-That (($rows['dup'] -split '\|')[1] -match "^M=err:config: budget\.maxCreditsPerPacket names size M more than once") 'a size table that names one size twice, by case, throws' $p.Text
        foreach ($k in 'zero', 'neg', 'string', 'bool', 'quoted', 'list') {
            Assert-That ($null -ne $rows[$k] -and @($rows[$k] -split '\|' | Where-Object { $_ -notmatch "^[SML]=$named" }).Count -eq 0) "maxCreditsPerPacket $k throws for every size, naming budget.maxCreditsPerPacket" $p.Text
        }
        # A broken ceiling (and a broken models.agents) is checked where it is used: board and progress still load.
        $broken = Get-TemplateConfig; $broken.budget.maxCreditsPerPacket = 'lots'; $broken.models.agents = @{ 'packet-reviewer-max' = 'premium' }
        [System.IO.File]::WriteAllText((Join-Path $caseRepo '.github/packet-workflow.json'), ($broken | ConvertTo-Json -Depth 10), $utf8)
        & git add -A; & git commit -qm 'a broken ceiling' | Out-Null; & git push -q origin main 2>$null; & git fetch -q origin
        $r = Invoke-Kit $caseBoard @('show')
        $r2 = Invoke-Kit $caseProgress @('-Json')
        Assert-That ($r.Code -eq 0 -and $r2.Code -eq 0) 'a config with a broken ceiling still loads for board show and progress.ps1' "$($r.Text)`n$($r2.Text)"
        $p = Invoke-CaseProbe "try { Get-PwCreditCeiling -Config (Get-PwConfig) -Size M } catch [PwError] { `"err:`$(`$_.Exception.Message)`" }"
        Assert-That ($p.Text -match "^$named" -and $p.Text -match "got 'lots'") 'and Get-PwCreditCeiling stops on it' $p.Text
    }
    finally { Pop-Location }

    Write-Host '  models.agents'
    # The classes install.ps1 writes today, read from its own table.
    $installed = [ordered]@{}
    foreach ($m in [regex]::Matches((Get-Content -Raw (Join-Path $kit 'install.ps1')), "'(packet-[\w-]+)\.agent\.md'\s*=\s*'(\w+)'")) { $installed[$m.Groups[1].Value] = $m.Groups[2].Value }
    $agentList = (@($installed.Keys) + 'my-reviewer' | ForEach-Object { "'$_'" }) -join ', '
    $p = Invoke-CaseProbe @"
function Classes(`$Models) { (@($agentList) | ForEach-Object { `$v = Get-PwAgentModelClass -Models `$Models -Agent `$_; "`$_=`$(if (`$null -eq `$v) { '<null>' } else { `$v })" }) -join '|' }
function Attempt(`$Models) { try { Classes `$Models } catch [PwError] { "err:`$(`$_.Exception.Message)" } }
"kit      `$(Classes `$script:Defaults.models)"
"nomodels `$(Classes `$null)"
"table    `$((`$script:AgentModelClass.Keys | ForEach-Object { "`$_=`$(`$script:AgentModelClass[`$_])" }) -join '|')"
"override `$(Classes (Merge-PwHashtable `$script:Defaults.models @{ agents = @{ 'packet-dispatcher' = 'standard' } }))"
"badagent `$(Attempt @{ agents = @{ 'packet-reviewer-max' = 'strong' } })"
"badclass `$(Attempt @{ agents = @{ 'packet-implementer' = 'premium' } })"
"notmap   `$(Attempt @{ agents = 'standard' })"
"list     `$(Attempt @{ agents = @(@{ 'packet-dispatcher' = 'light' }) })"
"empty    `$(Attempt @{ agents = @() })"
"case     `$(Attempt @{ agents = @{ 'Packet-Dispatcher' = 'light' } })"
"@
    $rows = @{}; foreach ($line in ($p.Text -split "`n")) { if ($line -match '^(\w+)\s+(.*)$') { $rows[$Matches[1]] = $Matches[2] } }
    $want = (($installed.Keys | ForEach-Object { "$_=$($installed[$_])" }) + 'my-reviewer=<null>') -join '|'
    $wantTable = ($installed.Keys | ForEach-Object { "$_=$($installed[$_])" }) -join '|'
    $wantOverride = (($installed.Keys | ForEach-Object { "$_=$(if ($_ -eq 'packet-dispatcher') { 'standard' } else { $installed[$_] })" }) + 'my-reviewer=<null>') -join '|'
    Assert-That ($installed.Count -eq 5 -and $rows['kit'] -eq $want -and $rows['nomodels'] -eq $want -and $rows['table'] -eq $wantTable) 'Get-PwAgentModelClass gives the five agents the classes install.ps1 writes today' "install.ps1: $wantTable`n$($p.Text)"
    Assert-That ($rows['override'] -eq $wantOverride) 'with { "packet-dispatcher": "standard" } only the dispatcher changes' $p.Text
    Assert-That ($rows['kit'] -match '\|my-reviewer=<null>$') 'an agent the kit doesn''t ship gives $null' $p.Text
    Assert-That ($rows['badagent'] -match "^err:config: models\.agents\.packet-reviewer-max is not one of the kit's agents") 'a models.agents key packet-reviewer-max throws' $p.Text
    Assert-That ($rows['badclass'] -match "^err:config: models\.agents\.packet-implementer must be strong, standard or light \(got 'premium'\)") 'a class premium throws' $p.Text
    Assert-That ($rows['notmap'] -match '^err:config: models\.agents must map' -and $rows['list'] -match '^err:config: models\.agents must map' -and $rows['empty'] -match '^err:config: models\.agents must map') 'a models.agents that isn''t a map throws, a one-item or empty list included' $p.Text
    Assert-That ($rows['case'] -match "^err:config: models\.agents\.Packet-Dispatcher is not one of the kit's agents") 'agent names are matched case-sensitively' $p.Text
    # Through Get-PwConfig too: a key that differs from a kit agent's only by case still reaches the check.
    $dupPath = Join-Path $tmp 'agents-dup.json'
    $dupText = ((Get-TemplateConfig) | ConvertTo-Json -Depth 10) -replace '"agents":\s*\{\s*\}', '"agents": { "packet-dispatcher": "light", "PACKET-DISPATCHER": "strong" }'
    [System.IO.File]::WriteAllText($dupPath, $dupText, $utf8)
    Push-Location -LiteralPath $caseRepo
    try { $p = Invoke-CaseProbe "try { Get-PwAgentModelClass -Models (Get-PwConfig -Path '$dupPath').models -Agent 'packet-dispatcher' } catch [PwError] { `"err:`$(`$_.Exception.Message)`" }" }
    finally { Pop-Location }
    Assert-That ($dupText -match 'PACKET-DISPATCHER' -and $p.Text -match "^err:config: models\.agents\.PACKET-DISPATCHER is not one of the kit's agents") 'a case-only duplicate agent name in the config is caught after Get-PwConfig merges it' "$($p.Text)"
    $tpl = Get-Content -Raw (Join-Path $kit 'templates/packet-workflow.json') | ConvertFrom-Json -AsHashtable
    Assert-That ($tpl.models.agents -is [System.Collections.IDictionary] -and $tpl.models.agents.Count -eq 0 -and $tpl.review.Contains('tierCap') -and $null -eq $tpl.review.tierCap -and $tpl.budget.Contains('maxCreditsPerPacket') -and $null -eq $tpl.budget.maxCreditsPerPacket) 'the template has "agents": {}, "tierCap": null and "maxCreditsPerPacket": null' ''
    $p = Invoke-CaseProbe "foreach (`$c in 'strong', 'standard', 'light') { `"`$c=`$(`$script:Defaults.models[`$c] -join ',')`" }"
    $wantModels = (@('strong', 'standard', 'light') | ForEach-Object { "$_=$($tpl.models[$_] -join ',')" }) -join "`n"
    Assert-That ($p.Text.Trim() -eq $wantModels) 'the defaults'' model lists are the template''s' "want:`n$wantModels`ngot:`n$($p.Text)"

    Write-Host '  $script:KitLenses'
    $files = [string[]]@(Get-ChildItem -LiteralPath (Join-Path $skills 'packet-review/lenses') -File -Filter '*.md' | ForEach-Object { $_.BaseName })
    [Array]::Sort($files, [StringComparer]::Ordinal)
    $p = Invoke-CaseProbe "`$n = [string[]]@(`$script:KitLenses); [Array]::Sort(`$n, [StringComparer]::Ordinal); `"`$(`$script:KitLenses.GetType().Name)|`$(`$n -join ',')`""
    Assert-That ($files.Count -eq 11 -and $p.Text.Trim() -ceq "String[]|$($files -join ',')") '$script:KitLenses equals the base names of skills/packet-review/lenses/*.md' "files: $($files -join ',')`n$($p.Text)"

    Write-Host '  the case-file runner'
    # Fixtures, run by the runner on their own (-CasesPath). Ordinal order puts 'B' before 'a'.
    $fixtures = Join-Path $tmp 'cases'
    New-Item -ItemType Directory -Path $fixtures | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $fixtures 'A-sets.tests.ps1'), "`$leak = 'set'; `$kit = 'clobbered'`nAssert-That `$true 'fixture A asserts'`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $fixtures 'B-reads.tests.ps1'), "Assert-That (-not (Test-Path variable:leak)) 'fixture B does not see A''s variable'`nAssert-That (Test-Path (Join-Path `$kit 'install.ps1')) 'fixture B sees the suite''s own `$kit'`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $fixtures 'a-throws.tests.ps1'), "throw 'fixture a gives up'`n", $utf8)
    [System.IO.File]::WriteAllText((Join-Path $fixtures 'ignored.ps1'), "throw 'not a case file'`n", $utf8)
    $r = Invoke-Kit $runner @('-CasesPath', $fixtures)
    $ord = [StringComparison]::Ordinal
    $iA = $r.Text.IndexOf('cases/A-sets.tests.ps1', $ord); $iB = $r.Text.IndexOf('cases/B-reads.tests.ps1', $ord); $iLower = $r.Text.IndexOf('cases/a-throws.tests.ps1', $ord)
    Assert-That ($r.Text -match '(?m)^\s+ok\s+fixture A asserts' -and $r.Text -match '(?m)^3 passed, 1 failed$') 'a case file''s asserts count in the summary' $r.Text
    Assert-That ($r.Code -eq 1 -and $r.Text -match '(?m)^\s+FAIL\s+cases/a-throws\.tests\.ps1 ran to the end' -and $r.Text -match 'fixture a gives up') 'a case file that throws adds one failure, named after the file, and the run exits 1' $r.Text
    Assert-That ($r.Text -match '(?m)^\s+ok\s+fixture B does not see A''s variable' -and $r.Text -match '(?m)^\s+ok\s+fixture B sees the suite''s own \$kit') 'a variable one case file sets is not seen by the next, nor does it reach the suite''s' $r.Text
    Assert-That ($iA -ge 0 -and $iA -lt $iB -and $iB -lt $iLower -and $r.Text -notmatch 'not a case file') 'case files run in ordinal file-name order, and only *.tests.ps1' $r.Text
    $empty = Join-Path $tmp 'no-cases'
    New-Item -ItemType Directory -Path $empty | Out-Null
    $r = Invoke-Kit $runner @('-CasesPath', $empty)
    Assert-That ($r.Code -eq 0 -and $r.Text -ceq "`n0 passed, 0 failed") 'with no case files the runner prints nothing of its own' $r.Text
    $r = Invoke-Kit $runner @('-CasesPath', (Join-Path $tmp 'no-such-folder'))
    Assert-That ($r.Code -eq 2 -and $r.Text -match 'run-tests: -CasesPath: no folder at ' -and $r.Text -notmatch 'passed') 'a -CasesPath folder that doesn''t exist stops the run (exit 2), never a pass' $r.Text
    # The default run's case loop: the same Invoke-CaseFiles, called once, printing nothing for no files.
    $quiet = @(Invoke-CaseFiles (Join-Path $tmp 'no-such-folder') 6>&1) + @(Invoke-CaseFiles $empty 6>&1)
    $calls = @(Select-String -LiteralPath $runner -SimpleMatch -Pattern "Invoke-CaseFiles (Join-Path `$PSScriptRoot 'cases')")
    Assert-That ($quiet.Count -eq 0 -and $calls.Count -eq 1) 'the default run calls Invoke-CaseFiles on tests/cases once, and it prints nothing when there are no case files' "output: $($quiet -join ' / '); calls: $($calls.Count)"

    Write-Host '  Remove-CaseRepo'
    if ($Keep) { Write-Host '  skip  Remove-CaseRepo checks: the run was started with -Keep' }
    else {
        $gone = New-CaseRepo
        Remove-CaseRepo $gone
        $kept = New-CaseRepo
        Remove-CaseRepo $kept -Keep 6>$null
        $keptBoth = (Test-Path -LiteralPath $kept) -and (Test-Path -LiteralPath "$kept-origin")
        Remove-CaseRepo $kept
        Assert-That (-not (Test-Path -LiteralPath $gone) -and -not (Test-Path -LiteralPath "$gone-origin")) 'Remove-CaseRepo removes the repository and its origin' $gone
        Assert-That ($keptBoth -and -not (Test-Path -LiteralPath $kept) -and -not (Test-Path -LiteralPath "$kept-origin")) 'with -Keep it leaves both' $kept
    }

    Write-Host '  case-file rules'
    # A $script: assignment, or a dot-sourced script (a kit script dot-sourced here assigns the kit's
    # $script: variables in the runner's scope; Invoke-CaseProbe runs kit code in a child pwsh instead).
    $assignRule = '(?i)(\$script:\w+\s*(\+\+|--|[-+*/%]?=(?!=))|(\+\+|--)\$script:\w+|Set-Variable\b.*-Scope\s+Script)'
    $dotRule = '(^|[;{(|]|&&)\s*\.\s+(\$|\(|[''"]|[\w./\\~-]+\.ps1\b)'
    # The samples spell the dot-source operator as DOT, so this file doesn't trip its own check.
    $samples = [ordered]@{ 'DOT $pw' = $true; '  DOT (Join-Path $skills "packet-board/scripts/PacketWorkflow.ps1")' = $true; 'try { DOT ''/k/PacketWorkflow.ps1'' }' = $true; 'DOT ./skills/x.ps1' = $true; '$v = 1.5' = $false; '# ends here. Then' = $false; '$a.b . c' = $false; '"text. $x"' = $false }
    $missed = @($samples.Keys | Where-Object { (($_ -creplace 'DOT', '.') -match $dotRule) -ne $samples[$_] })
    Assert-That ($missed.Count -eq 0) 'the dot-source rule matches dot-sourcing and nothing else in the samples' "wrong: $($missed -join ' | ')"
    $broken = foreach ($f in Get-ChildItem -LiteralPath (Join-Path $kit 'tests/cases') -File -Filter '*.ps1') {
        $n = 0
        foreach ($line in [System.IO.File]::ReadAllLines($f.FullName)) {
            $n++
            if ($line -match $assignRule -or $line -match $dotRule) { "$($f.Name):${n}: $line" }
        }
    }
    Assert-That (-not $broken) 'no file in tests/cases assigns a $script: variable or dot-sources a script' (@($broken) -join "`n")
}
finally {
    Remove-CaseRepo $caseRepo
    if (-not $Keep) { Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue }
}
