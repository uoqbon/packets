# solo-install.tests.ps1 (PKT-4): install.ps1 -Profile solo, the solo overlay, a model class per agent
# (models.agents), the Local harness warning, and -PlanOnly -Profile solo.
# Run by tests/run-tests.ps1 in a child scope: plain variables only, never a script-scope one, and kit
# code only through Invoke-Kit, Invoke-CaseProbe or New-CaseRepo (never dot-sourced here).

$installer = Join-Path $kit 'install.ps1'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$templatePath = Join-Path $kit 'templates/packet-workflow.json'
$overlayPath = Join-Path $kit 'templates/packet-workflow.solo.json'
# A fresh repository with a GitHub origin and origin/HEAD at trunk, so repo and the default branch get filled in.
function New-SoloTarget {
    $t = Join-Path ([System.IO.Path]::GetTempPath()) ("pw-solo-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
    New-Item -ItemType Directory -Path $t | Out-Null
    foreach ($gitArgs in @(@('init', '-q', '-b', 'trunk'), @('remote', 'add', 'origin', 'https://github.com/acme/widgets.git'), @('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/trunk'))) {
        $out = & git -C $t @gitArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "New-SoloTarget: git $($gitArgs -join ' ') failed: $out" }
    }
    $t
}
# Every file under a folder (dotfiles too), as sorted relative paths with forward slashes.
function Get-SoloTree([string]$Root, [switch]$Hidden) {
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force:$Hidden | ForEach-Object { [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/') } | Sort-Object { $_ } -Culture ([cultureinfo]::InvariantCulture))
}
# Every file under .github with its hash, as one string to compare.
function Get-SoloSnapshot([string]$Repo) {
    $gh = Join-Path $Repo '.github'
    (Get-SoloTree $gh -Hidden | ForEach-Object { "$_ $((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $gh $_)).Hash)" }) -join "`n"
}
# Every key path of a parsed JSON table, in order (lists are leaves).
function Get-KeyPaths($Node, [string]$Prefix = '') {
    if ($Node -isnot [System.Collections.IDictionary]) { return }
    foreach ($k in $Node.Keys) { "$Prefix$k"; Get-KeyPaths $Node[$k] "$Prefix$k." }
}
function Read-Json([string]$Path) { Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable }
function Write-Json([string]$Path, $Value) { [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 10) + "`n", $utf8) }
# The model: line an agent should carry for a list of models, as install.ps1 quotes it.
function Get-ModelLine([string[]]$List) { 'model: [' + (($List | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', ') + ']' }
function Get-AgentModelLine([string]$Repo, [string]$Agent) { @(Get-Content -LiteralPath (Join-Path $Repo ".github/agents/$Agent.agent.md") | Where-Object { $_ -match '^model:' })[0] }
# The output with colours and the console's line wrapping taken out, so a long warning matches as one line.
function Get-Flat([string]$Text) { $Text -replace "`e\[[0-9;]*m", '' -replace '\s*\n\s*', ' ' }

# The solo config as the packet defines it: the template, those six values set in place, repo and branch filled.
$soloWant = Read-Json $templatePath
$soloWant.repo = 'acme/widgets'; $soloWant.defaultBranch = 'trunk'; $soloWant.guardrails.protectedBranches = @('trunk')
$soloWant.review.maxRounds = 2; $soloWant.review.lensesPerReviewer = 3; $soloWant.review.shouldFixPassFromRound = 2; $soloWant.review.tierCap = 2
$soloWant.models.agents['packet-dispatcher'] = 'standard'
$soloWant.budget.maxCreditsPerPacket = [ordered]@{ S = 950; M = 1500; L = 2200 }
$soloWantJson = $soloWant | ConvertTo-Json -Depth 10
$kitAgents = @('packet-dispatcher', 'packet-reviewer-deep', 'packet-implementer', 'packet-reviewer-standard', 'packet-reviewer-light')

$fresh = $null; $classes = $null; $existing = $null; $bad = $null; $planOnly = $null; $plain = $null
try {
    Write-Host '  the solo overlay'
    $overlay = Read-Json $overlayPath
    $paths = @(Get-KeyPaths $overlay)
    $wantPaths = @('models', 'models.agents', 'models.agents.packet-dispatcher', 'review', 'review.maxRounds', 'review.lensesPerReviewer', 'review.shouldFixPassFromRound', 'review.tierCap', 'budget', 'budget.maxCreditsPerPacket', 'budget.maxCreditsPerPacket.S', 'budget.maxCreditsPerPacket.M', 'budget.maxCreditsPerPacket.L')
    Assert-That (($paths -join ',') -ceq ($wantPaths -join ',')) 'templates/packet-workflow.solo.json holds only the overlay''s keys: no model lists, no creditsPerRun' ($paths -join ', ')
    $vals = "$($overlay.review.maxRounds) $($overlay.review.lensesPerReviewer) $($overlay.review.shouldFixPassFromRound) $($overlay.review.tierCap) $($overlay.models.agents['packet-dispatcher']) $($overlay.budget.maxCreditsPerPacket.S) $($overlay.budget.maxCreditsPerPacket.M) $($overlay.budget.maxCreditsPerPacket.L)"
    Assert-That ($vals -ceq '2 3 2 2 standard 950 1500 2200') 'with the packet''s values: 2 rounds, 3 lenses a run, should-fix passes from round 2, tier cap 2, the dispatcher on standard, ceilings 950 / 1500 / 2200' $vals

    Write-Host '  -Profile solo into a fresh repository'
    $fresh = New-SoloTarget
    $r = Invoke-Kit $installer @('-Target', $fresh, '-Profile', 'solo', '-DryRun')
    Assert-That ($r.Code -eq 0 -and -not (Test-Path (Join-Path $fresh '.github')) -and $r.Text -match 'add\s+\.github/packet-workflow\.json \(repo acme/widgets, default branch trunk; the solo profile;') '-Profile solo -DryRun names the solo config and writes nothing' $r.Text
    $r = Invoke-Kit $installer @('-Target', $fresh, '-Profile', 'solo')
    $cfgText = Get-Content -Raw -LiteralPath (Join-Path $fresh '.github/packet-workflow.json')
    $cfgGot = $cfgText | ConvertFrom-Json -AsHashtable
    Assert-That ($r.Code -eq 0 -and ($cfgGot | ConvertTo-Json -Depth 10) -ceq $soloWantJson) 'it writes the default template merged with the overlay, with repo and the default branch filled in' ("output:`n$($r.Text)`ngot:`n$($cfgGot | ConvertTo-Json -Depth 10)")
    $tplPaths = @(Get-KeyPaths (Read-Json $templatePath) | Where-Object { $_ -notlike 'models.agents.*' -and $_ -notlike 'budget.maxCreditsPerPacket.*' })
    $gotPaths = @(Get-KeyPaths $cfgGot | Where-Object { $_ -notlike 'models.agents.*' -and $_ -notlike 'budget.maxCreditsPerPacket.*' })
    Assert-That (($gotPaths -join ',') -ceq ($tplPaths -join ',') -and $cfgText.IndexOf('"agents": {') -lt $cfgText.IndexOf('"review": {') -and $cfgText.IndexOf('"maxRounds": 2') -lt $cfgText.IndexOf('"maxParallelLenses"')) 'the solo config''s keys come out in the default template''s order' ($gotPaths -join ', ')
    Assert-That ($cfgGot.budget.creditsPerRun.dispatcher -eq 25 -and ($cfgGot.models.strong -join '|') -ceq ((Read-Json $templatePath).models.strong -join '|')) 'creditsPerRun and the model lists are the default template''s' ($cfgGot.budget | ConvertTo-Json -Depth 5)
    Push-Location -LiteralPath $fresh
    try {
        $p = Invoke-CaseProbe '$c = Get-PwConfig; "rv $($c.review.maxRounds) $($c.review.lensesPerReviewer) $($c.review.shouldFixPassFromRound) $($c.review.tierCap)"; "ceiling $(Get-PwCreditCeiling -Config $c -Size S) $(Get-PwCreditCeiling -Config $c -Size M) $(Get-PwCreditCeiling -Config $c -Size L)"; "class $(Get-PwAgentModelClass -Models $c.models -Agent packet-dispatcher)"'
    }
    finally { Pop-Location }
    Assert-That ($p.Code -eq 0 -and $p.Text -match '(?m)^rv 2 3 2 2\r?$') 'Get-PwConfig on it gives maxRounds 2, lensesPerReviewer 3, shouldFixPassFromRound 2 and tierCap 2' $p.Text
    Assert-That ($p.Text -match '(?m)^ceiling 950 1500 2200\r?$' -and $p.Text -match '(?m)^class standard\r?$') 'and the ceilings per size, and the dispatcher on standard' $p.Text
    $shipped = @($kitAgents | Where-Object { (Get-AgentModelLine $fresh $_) -cne (Get-ModelLine (Read-Json $templatePath).models.strong) })
    Assert-That ($shipped.Count -eq 0 -and $r.Text -match 'Agent classes from models\.agents: packet-dispatcher on standard \(the kit''s: strong\)\.') 'with the shipped lists every agent gets the same models; the summary names the dispatcher''s class' ("$($shipped -join ', ')`n$($r.Text)")
    Assert-That ($r.Text -notmatch 'Local harness' -and $r.Text -notmatch 'WARNING') 'with identical lists (both templates as shipped) it doesn''t warn' $r.Text

    Write-Host '  a model class per agent'
    $classes = New-SoloTarget
    New-Item -ItemType Directory -Path (Join-Path $classes '.github') | Out-Null
    $c = Read-Json $templatePath
    $c.repo = 'acme/widgets'
    $c.models.strong = @('Strong One (copilot)', 'Strong Two (copilot)'); $c.models.standard = @('Standard One (copilot)'); $c.models.light = @("Light's One (copilot)")
    $c.models.agents = [ordered]@{ 'packet-dispatcher' = 'standard' }
    Write-Json (Join-Path $classes '.github/packet-workflow.json') $c
    $r = Invoke-Kit $installer @('-Target', $classes)
    $lines = [ordered]@{}; foreach ($a in $kitAgents) { $lines[$a] = Get-AgentModelLine $classes $a }
    $wantLines = [ordered]@{ 'packet-dispatcher' = Get-ModelLine $c.models.standard; 'packet-reviewer-deep' = Get-ModelLine $c.models.strong; 'packet-implementer' = Get-ModelLine $c.models.standard; 'packet-reviewer-standard' = Get-ModelLine $c.models.standard; 'packet-reviewer-light' = Get-ModelLine $c.models.light }
    $wrong = @($kitAgents | Where-Object { $lines[$_] -cne $wantLines[$_] })
    Assert-That ($r.Code -eq 0 -and $wrong.Count -eq 0) 'each agent''s model: line is its class''s list: the dispatcher gets the standard list, the deep reviewer keeps the strong list' (($kitAgents | ForEach-Object { "$_ $($lines[$_])" }) -join "`n")
    $flat = Get-Flat $r.Text
    Assert-That ($flat -match 'WARNING: packet-dispatcher runs on the standard class \(Standard One \(copilot\)\), below packet-reviewer-deep \(strong: Strong One \(copilot\) > Strong Two \(copilot\)\)\.' -and $flat -match "In VS Code's Local harness, a subagent on a model in a higher cost tier than the session's doesn't run" -and $flat -match 'stops at Needs human' -and $flat -match 'run those dispatches in a session on the higher model, or give that agent the dispatcher''s class') 'with different strong and standard lists and the dispatcher on standard, it warns, naming packet-reviewer-deep, the Local harness, Needs human and both fixes' $r.Text
    Assert-That ($flat -notmatch 'below [^.]*packet-(implementer|reviewer-standard|reviewer-light)') 'and names no subagent on the dispatcher''s class or below it' $r.Text
    # The deep reviewer moved to the dispatcher's class: nothing ranks above the dispatcher, so no warning.
    $c.models.agents['packet-reviewer-deep'] = 'standard'
    Write-Json (Join-Path $classes '.github/packet-workflow.json') $c
    $r = Invoke-Kit $installer @('-Target', $classes)
    Assert-That ($r.Code -eq 0 -and (Get-AgentModelLine $classes 'packet-reviewer-deep') -ceq (Get-ModelLine $c.models.standard) -and $r.Text -notmatch 'Local harness' -and (Get-Flat $r.Text) -match 'Agent classes from models\.agents: packet-dispatcher on standard \(the kit''s: strong\); packet-reviewer-deep on standard \(the kit''s: strong\)\.') 'giving the deep reviewer the dispatcher''s class rewrites it and ends the warning; the summary names both' $r.Text
    # Dispatcher on light, lists that differ only between strong and the rest: the strong-class reviewer is named.
    $c.models.agents = [ordered]@{ 'packet-dispatcher' = 'light' }
    $c.models.standard = @("Light's One (copilot)")
    Write-Json (Join-Path $classes '.github/packet-workflow.json') $c
    $flat = Get-Flat (Invoke-Kit $installer @('-Target', $classes)).Text
    Assert-That ($flat -match 'WARNING: packet-dispatcher runs on the light class [^.]*below packet-reviewer-deep \(strong: Strong One \(copilot\) > Strong Two \(copilot\)\)\. In VS Code' -and $flat -match 'give that agent the dispatcher') 'a higher class with the same list as the dispatcher''s (standard here) is not named; one with another list is' $flat
    # No models.agents: the kit's classes, and the dispatcher on strong is never below a subagent.
    $c.models.Remove('agents')
    Write-Json (Join-Path $classes '.github/packet-workflow.json') $c
    $r = Invoke-Kit $installer @('-Target', $classes)
    Assert-That ($r.Code -eq 0 -and (Get-AgentModelLine $classes 'packet-dispatcher') -ceq (Get-ModelLine $c.models.strong) -and $r.Text -notmatch 'Local harness' -and $r.Text -notmatch 'Agent classes from models\.agents') 'without models.agents each agent is back on the kit''s class, with no warning and no class line' $r.Text

    # A hand-edited dispatcher is kept with its own model: line, so its class can't put it below a subagent.
    $dispFile = Join-Path $classes '.github/agents/packet-dispatcher.agent.md'
    [System.IO.File]::WriteAllText($dispFile, ([System.IO.File]::ReadAllText($dispFile) -replace '(?m)^model:.*$', "model: ['Hand Picked']"), $utf8)
    $c.models.agents = [ordered]@{ 'packet-dispatcher' = 'standard' }
    Write-Json (Join-Path $classes '.github/packet-workflow.json') $c
    $r = Invoke-Kit $installer @('-Target', $classes)
    Assert-That ($r.Code -eq 0 -and (Get-AgentModelLine $classes 'packet-dispatcher') -ceq "model: ['Hand Picked']" -and $r.Text -match 'kept\s+\.github/agents/packet-dispatcher\.agent\.md' -and $r.Text -notmatch 'Local harness' -and $r.Text -notmatch 'Agent classes from models\.agents') 'a kept dispatcher is named as kept, with no class line and no warning from a class it doesn''t run on' $r.Text

    Write-Host '  the default profile'
    $plain = New-SoloTarget
    $r = Invoke-Kit $installer @('-Target', $plain)
    $changed = @(Get-ChildItem -LiteralPath (Join-Path $kit 'agents') -Filter '*.agent.md' | Where-Object { (Get-FileHash $_.FullName).Hash -ne (Get-FileHash (Join-Path $plain ".github/agents/$($_.Name)")).Hash })
    $plainCfg = Read-Json (Join-Path $plain '.github/packet-workflow.json')
    $plainWant = Read-Json $templatePath
    $plainWant.repo = 'acme/widgets'; $plainWant.defaultBranch = 'trunk'; $plainWant.guardrails.protectedBranches = @('trunk')
    Assert-That ($r.Code -eq 0 -and $changed.Count -eq 0 -and ($plainCfg | ConvertTo-Json -Depth 10) -ceq ($plainWant | ConvertTo-Json -Depth 10)) 'with the default profile and no models.agents, every installed agent equals its source and the config is the template, as before' (($changed | ForEach-Object Name) -join ', ')
    Assert-That ($r.Text -notmatch 'Agent classes from models\.agents' -and $r.Text -notmatch 'Local harness' -and $r.Text -notmatch 'profile') 'and the output names no class, warning or profile' $r.Text
    $r = Invoke-Kit $installer @('-Target', $plain, '-Profile', 'Default')
    Assert-That ($r.Code -eq 0 -and $r.Text -notmatch 'already exists') '-Profile default on an existing config reports nothing about it' $r.Text
    $before = Get-SoloSnapshot $plain
    $r = Invoke-Kit $installer @('-Target', $plain, '-Profile', 'lean')
    Assert-That ($r.Code -ne 0 -and (Get-SoloSnapshot $plain) -ceq $before) 'an unknown profile is refused, and nothing is written' $r.Text

    Write-Host '  -Profile solo on an existing config'
    $existing = New-SoloTarget
    New-Item -ItemType Directory -Path (Join-Path $existing '.github') | Out-Null
    $e = Read-Json $templatePath
    $e.repo = 'someone/else'; $e.board.provider = 'local'; $e.labels.packet = 'work'; $e.review.lensesPerReviewer = 3.0; $e.models.agents = [ordered]@{ 'packet-reviewer-light' = 'standard' }
    $e.budget.maxCreditsPerPacket = [ordered]@{ S = 950; M = 1200; L = 2200 }
    $cfgFile = Join-Path $existing '.github/packet-workflow.json'
    # CRLF and no final newline, so a rewrite of any kind would show.
    [System.IO.File]::WriteAllText($cfgFile, (($e | ConvertTo-Json -Depth 10) -replace "`r?`n", "`r`n"), $utf8)
    $cfgHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $cfgFile).Hash
    $r = Invoke-Kit $installer @('-Target', $existing, '-Profile', 'solo')
    $listed = @($r.Text -split "`n" | Where-Object { $_ -match '^  [\w.-]+: .* -> ' } | ForEach-Object { $_.Trim() })
    $wantListed = @(
        'review.maxRounds: 3 -> 2'
        'review.shouldFixPassFromRound: null -> 2'
        'review.tierCap: null -> 2'
        'models.agents.packet-dispatcher: (not set) -> "standard"'
        'budget.maxCreditsPerPacket.M: 1200 -> 1500')
    Assert-That ($r.Code -eq 0 -and (Get-FileHash -Algorithm SHA256 -LiteralPath $cfgFile).Hash -eq $cfgHash) 'it leaves the config byte-identical' $r.Text
    Assert-That ($r.Text -match '\.github/packet-workflow\.json already exists, so -Profile solo left it as it is\.' -and ((@($listed | Sort-Object) -join "`n") -ceq (@($wantListed | Sort-Object) -join "`n"))) 'and lists only the overlay''s keys that differ (review.maxRounds: 3 -> 2 among them)' ("got:`n$($listed -join "`n")`n`noutput:`n$($r.Text)")
    Assert-That ((Get-Content -Raw -LiteralPath $cfgFile) -match '"lensesPerReviewer": 3\.0' -and $r.Text -notmatch '(?m)^\s+(repo|board|labels|version|models\.(strong|standard|light)|models\.agents\.packet-reviewer-light|review\.lensesPerReviewer|budget\.creditsPerRun)\b') 'never repo, the board or another key the overlay doesn''t hold, nor one that already matches (3.0 matches 3)' $r.Text
    $e2 = Read-Json $cfgFile
    Assert-That ($e2.review.maxRounds -eq 3 -and (Get-AgentModelLine $existing 'packet-dispatcher') -ceq (Get-ModelLine $e.models.strong) -and $r.Text -notmatch 'packet-dispatcher on standard') 'the agents follow the config, not the profile: the dispatcher stays on strong' $r.Text
    $r = Invoke-Kit $installer @('-Target', $fresh, '-Profile', 'solo')
    Assert-That ($r.Code -eq 0 -and $r.Text -match 'already has the solo profile''s settings' -and $r.Text -notmatch ' -> ') 'a config that already has the solo settings lists none' $r.Text

    Write-Host '  a bad models.agents entry'
    $bad = New-SoloTarget
    $r = Invoke-Kit $installer @('-Target', $bad)
    Assert-That ($r.Code -eq 0) 'a first install, to change the config of' $r.Text
    $badCfg = Join-Path $bad '.github/packet-workflow.json'
    $good = Read-Json $badCfg
    $cases = [ordered]@{
        'packet-reviewer-max' = @{ agents = [ordered]@{ 'packet-reviewer-max' = 'strong' }; message = "models\.agents\.packet-reviewer-max is not one of the kit's agents" }
        'premium'             = @{ agents = [ordered]@{ 'packet-reviewer-deep' = 'premium' }; message = "models\.agents\.packet-reviewer-deep must be strong, standard or light \(got 'premium'\)" }
    }
    foreach ($name in $cases.Keys) {
        $good.models.agents = $cases[$name].agents
        Write-Json $badCfg $good
        # With -Force and -WithInstructions a run that went on would rewrite the manifest (its installedAt)
        # and add copilot-instructions.md, so any write shows in the snapshot.
        $before = Get-SoloSnapshot $bad
        $r0 = Invoke-Kit $installer @('-Target', $bad, '-Profile', 'solo', '-Force')
        $r = Invoke-Kit $installer @('-Target', $bad, '-Force', '-WithInstructions')
        Assert-That ($r0.Code -ne 0 -and $r.Code -ne 0 -and (Get-SoloSnapshot $bad) -ceq $before -and (Get-Flat $r.Text) -match $cases[$name].message -and $r.Text -match 'Nothing was written') "a models.agents entry naming $name makes the install exit non-zero before it writes; the target's files and manifest are unchanged" ("code $($r.Code)`n$($r.Text)")
    }
    Assert-That ($r.Code -eq 2) 'it exits 2, as the kit''s scripts do on an error' "code $($r.Code)"
    $r = Invoke-Kit $installer @('-Target', $bad, '-PlanOnly')
    Assert-That ($r.Code -ne 0 -and $r.Text -match 'refused') '(-PlanOnly on that full install is still refused first, as PKT-2 has it)' $r.Text

    Write-Host '  -PlanOnly -Profile solo'
    $planOnly = New-SoloTarget
    $r = Invoke-Kit $installer @('-Target', $planOnly, '-PlanOnly', '-Profile', 'solo')
    $planOnlyRe = '^\.github/skills/(packet-plan|packet-board|packet-progress)/|^\.github/skills/packet-dispatch/scripts/check-scope\.ps1$'
    $wantSkills = @(Get-SoloTree (Join-Path $kit 'skills') | ForEach-Object { ".github/skills/$_" } | Where-Object { $_ -match $planOnlyRe })
    $tree = @(Get-SoloTree (Join-Path $planOnly '.github') -Hidden | ForEach-Object { ".github/$_" })
    $want = @($wantSkills + '.github/packet-workflow.json' + '.github/packet-workflow.kit.json' | Sort-Object { $_ } -Culture ([cultureinfo]::InvariantCulture))
    $man = Read-Json (Join-Path $planOnly '.github/packet-workflow.kit.json')
    Assert-That ($r.Code -eq 0 -and ($tree -join "`n") -ceq ($want -join "`n") -and $man.mode -ceq 'plan-only') 'it installs the plan-only files, and the manifest says plan-only' ("output:`n$($r.Text)`ngot:`n$($tree -join "`n")")
    $poCfg = Read-Json (Join-Path $planOnly '.github/packet-workflow.json')
    Assert-That (($poCfg | ConvertTo-Json -Depth 10) -ceq $soloWantJson -and $r.Text -notmatch 'Agent models' -and $r.Text -notmatch 'Local harness') 'with the solo config, and no agent models or warning' ($poCfg | ConvertTo-Json -Depth 10)
}
finally {
    foreach ($dir in $fresh, $classes, $existing, $bad, $planOnly, $plain) {
        if ($dir -and (Test-Path -LiteralPath $dir)) { if ($Keep) { Write-Host "  kept  $dir" } else { Remove-Item -Recurse -Force -LiteralPath $dir } }
    }
}
