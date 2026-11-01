# plan-only.tests.ps1 (PKT-2): install.ps1 -PlanOnly, the mode in the manifest, changing mode, the
# plan-only instructions block, the validator's lens fallback, and the docs for working without a dispatcher.
# Run by tests/run-tests.ps1 in a child scope: plain variables only, never a script-scope one, and kit
# code only through Invoke-Kit, Invoke-CaseProbe or New-CaseRepo (never dot-sourced here).

$installer = Join-Path $kit 'install.ps1'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$planOnlyRe = '^\.github/skills/(packet-plan|packet-board|packet-progress)/|^\.github/skills/packet-dispatch/scripts/check-scope\.ps1$'
# Every file under a folder, as relative paths with forward slashes, sorted.
function Get-Tree([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object { [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/') } | Sort-Object { $_ } -Culture ([cultureinfo]::InvariantCulture))
}
# Every file under .github with its hash, as one string to compare.
function Get-Snapshot([string]$Repo) {
    $gh = Join-Path $Repo '.github'
    (Get-Tree $gh | ForEach-Object { "$_ $((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $gh $_)).Hash)" }) -join "`n"
}
function Get-Manifest([string]$Repo) { Get-Content -Raw (Join-Path $Repo '.github/packet-workflow.kit.json') | ConvertFrom-Json -AsHashtable }
function Get-Block([string]$Repo) {
    $t = Get-Content -Raw (Join-Path $Repo '.github/copilot-instructions.md')
    [pscustomobject]@{ Count = ([regex]::Matches($t, '<!-- packet-workflow:start -->')).Count + ([regex]::Matches($t, '<!-- packet-workflow:end -->')).Count; Text = $t }
}
function New-BareTarget {
    $t = Join-Path ([System.IO.Path]::GetTempPath()) ("pw-planonly-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
    New-Item -ItemType Directory -Path $t | Out-Null
    & git -C $t init -q -b trunk
    & git -C $t remote add origin https://github.com/acme/widgets.git
    & git -C $t symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
    $t
}
# The files a plan-only install should hold, from the kit's own skills folder.
$wantSkills = @(Get-Tree (Join-Path $kit 'skills') | ForEach-Object { ".github/skills/$_" } | Where-Object { $_ -match $planOnlyRe })
$fullTemplate = (Get-Content -Raw (Join-Path $kit 'templates/copilot-instructions.md')).Trim()
$planTemplate = (Get-Content -Raw (Join-Path $kit 'templates/copilot-instructions.plan-only.md')).Trim()

$target = New-BareTarget
$models = New-BareTarget
$caseRepo = $null
$pinned = Join-Path ([System.IO.Path]::GetTempPath()) ("pw-pinned-" + [guid]::NewGuid().ToString('n').Substring(0, 8))
try {
    Write-Host '  -PlanOnly into a fresh repository'
    Set-Content -LiteralPath (Join-Path $target 'notes.txt') -Value 'x'
    $r = Invoke-Kit $installer @('-Target', $target, '-PlanOnly', '-DryRun', '-WithInstructions')
    Assert-That ($r.Code -eq 0 -and -not (Test-Path (Join-Path $target '.github')) -and $r.Text -match 'would be installed' -and $r.Text -match 'add\s+\.github/skills/packet-board/scripts/board\.ps1') '-PlanOnly -DryRun lists the files and writes nothing' $r.Text
    $r = Invoke-Kit $installer @('-Target', $target, '-PlanOnly')
    $tree = Get-Tree (Join-Path $target '.github') | ForEach-Object { ".github/$_" }
    $want = @($wantSkills + '.github/packet-workflow.json' + '.github/packet-workflow.kit.json' | Sort-Object { $_ } -Culture ([cultureinfo]::InvariantCulture))
    Assert-That ($r.Code -eq 0 -and ($tree -join "`n") -ceq ($want -join "`n")) 'it writes exactly the three skills, check-scope.ps1, the config and the manifest' ("output:`n$($r.Text)`ngot:`n$($tree -join "`n")`nwant:`n$($want -join "`n")")
    $dispatchFiles = @($tree | Where-Object { $_ -like '.github/skills/packet-dispatch/*' })
    Assert-That ($dispatchFiles.Count -eq 1 -and $dispatchFiles[0] -ceq '.github/skills/packet-dispatch/scripts/check-scope.ps1' -and (Test-Path (Join-Path $kit 'skills/packet-dispatch/SKILL.md'))) 'of packet-dispatch, only check-scope.ps1: no SKILL.md, so no /packet-dispatch' ($dispatchFiles -join ', ')
    $cfgWant = Get-Content -Raw (Join-Path $kit 'templates/packet-workflow.json') | ConvertFrom-Json -AsHashtable
    $cfgWant.repo = 'acme/widgets'; $cfgWant.defaultBranch = 'trunk'; $cfgWant.guardrails.protectedBranches = @('trunk')
    $cfgGot = Get-Content -Raw (Join-Path $target '.github/packet-workflow.json') | ConvertFrom-Json -AsHashtable
    Assert-That (($cfgGot | ConvertTo-Json -Depth 10) -ceq ($cfgWant | ConvertTo-Json -Depth 10)) 'the config is the full template, with repo and the default branch filled in' ($cfgGot | ConvertTo-Json -Depth 10)
    $man = Get-Manifest $target
    $manFiles = @($man.files.Keys | Sort-Object { $_ } -Culture ([cultureinfo]::InvariantCulture))
    $badHash = @($manFiles | Where-Object { $man.files[$_] -ne (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $target $_)).Hash.ToLowerInvariant() })
    Assert-That ($man.mode -ceq 'plan-only' -and ($manFiles -join "`n") -ceq ($wantSkills -join "`n") -and $badHash.Count -eq 0) 'the manifest records mode plan-only and lists only those files, with their hashes' ($man | ConvertTo-Json -Depth 5)
    Assert-That ($r.Text -match '\(plan only: planning, the board and progress\)' -and $r.Text -match 'This install has no agents, no hook and no /packet-dispatch' -and $r.Text -match 'Plan and board only' -and $r.Text -notmatch 'Agent models:' -and $r.Text -notmatch 'packet-dispatcher agent') 'it prints this mode''s next steps, and no agent models' $r.Text

    Write-Host '  the models map'
    New-Item -ItemType Directory -Path (Join-Path $models '.github') | Out-Null
    $c = Get-Content -Raw (Join-Path $kit 'templates/packet-workflow.json') | ConvertFrom-Json -AsHashtable
    $c.repo = 'acme/widgets'; $c.models = @{ strong = @() }
    [System.IO.File]::WriteAllText((Join-Path $models '.github/packet-workflow.json'), ($c | ConvertTo-Json -Depth 10), $utf8)
    $r = Invoke-Kit $installer @('-Target', $models, '-PlanOnly')
    Assert-That ($r.Code -eq 0 -and (Test-Path (Join-Path $models '.github/skills/packet-board/scripts/board.ps1')) -and -not (Test-Path (Join-Path $models '.github/agents'))) '-PlanOnly succeeds with "models": { "strong": [] }' $r.Text
    $before = Get-Snapshot $models
    $r = Invoke-Kit $installer @('-Target', $models)
    Assert-That ($r.Code -eq 1 -and $r.Text -match 'models\.strong in \.github/packet-workflow\.json must name at least one model' -and (Get-Snapshot $models) -ceq $before) 'without -PlanOnly the same config still fails as it does today, writing nothing' $r.Text

    Write-Host '  -WithInstructions in plan-only mode'
    [System.IO.File]::WriteAllText((Join-Path $target '.github/copilot-instructions.md'), "# Our rules`n`nBe kind.`n", $utf8)
    $r = Invoke-Kit $installer @('-Target', $target, '-PlanOnly', '-WithInstructions')
    $b = Get-Block $target
    Assert-That ($r.Code -eq 0 -and $b.Count -eq 2 -and $b.Text.Contains($planTemplate) -and $b.Text.StartsWith("# Our rules`n`nBe kind.")) 'it adds the plan-only block after the file''s own text' $b.Text
    Assert-That ($planTemplate -match '/packet-plan' -and $planTemplate -match '/packet-board' -and $planTemplate -match '/packet-progress' -and $planTemplate -notmatch '/packet-dispatch|/packet-review|packet-dispatcher|packet-implementer|packet-reviewer' -and $planTemplate -match '\*\*Agents never merge\*\*') 'the plan-only block names only the three skills, and says agents never merge' $planTemplate
    $r = Invoke-Kit $installer @('-Target', $target, '-PlanOnly', '-WithInstructions')
    $b = Get-Block $target
    Assert-That ($r.Code -eq 0 -and $b.Count -eq 2 -and $b.Text.Contains($planTemplate) -and $r.Text -notmatch 'copilot-instructions' -and $r.Text -match "$($wantSkills.Count) file\(s\) already up to date") 'a second plan-only run changes nothing' $r.Text

    Write-Host '  a full run on a plan-only install'
    $r = Invoke-Kit $installer @('-Target', $target)
    $first = @($r.Text -split "`n")[0]
    $man = Get-Manifest $target
    $added = @('.github/agents/packet-dispatcher.agent.md', '.github/agents/packet-implementer.agent.md', '.github/agents/packet-reviewer-deep.agent.md', '.github/skills/packet-dispatch/SKILL.md', '.github/skills/packet-review/SKILL.md', '.github/skills/packet-review/lenses/ops.md', '.github/hooks/packet-workflow.json', '.github/hooks/packet-dispatcher-guard.ps1')
    $missing = @($added | Where-Object { -not (Test-Path (Join-Path $target $_)) -or -not $man.files.Contains($_) })
    Assert-That ($r.Code -eq 0 -and $first -match '^This run makes the plan-only install full: it adds the agents \(\.github/agents\), the packet-dispatch and packet-review skills and the hook \(\.github/hooks\)\.$') 'its first line says it makes the install full and what it adds' $r.Text
    Assert-That ($missing.Count -eq 0 -and $man.mode -ceq 'full' -and $r.Text -match 'Agent models:') 'it adds the agents, the dispatch and review skills and the hook, and records mode full' "missing: $($missing -join ', ')`n$($r.Text)"
    Assert-That ((Get-Block $target).Text.Contains($planTemplate) -and $r.Text -match 'copilot-instructions\.md still holds the plan-only install''s workflow rules: rerun with -WithInstructions') 'without -WithInstructions it leaves the block alone and says to rerun with it' $r.Text
    $r = Invoke-Kit $installer @('-Target', $target, '-WithInstructions')
    $b = Get-Block $target
    Assert-That ($r.Code -eq 0 -and $b.Count -eq 2 -and $b.Text.Contains($fullTemplate) -and -not $b.Text.Contains($planTemplate) -and $b.Text.StartsWith("# Our rules")) 'a full run with -WithInstructions replaces it with the full block' $b.Text
    $r = Invoke-Kit $installer @('-Target', $target)
    Assert-That ($r.Code -eq 0 -and $r.Text -notmatch 'makes the plan-only install full' -and $r.Text -notmatch 'still holds') 'a full run on a full install says nothing about modes' $r.Text

    Write-Host '  -PlanOnly on a full install'
    $before = Get-Snapshot $target
    $r = Invoke-Kit $installer @('-Target', $target, '-PlanOnly', '-WithInstructions')
    $listed = @($r.Text -split "`n" | Where-Object { $_ -match '^  \.github/' } | ForEach-Object { $_.Trim() })
    $man = Get-Manifest $target
    $wantListed = @($man.files.Keys | Where-Object { $_ -notmatch $planOnlyRe } | Sort-Object)
    Assert-That ($r.Code -eq 1 -and $r.Text -match 'refused, nothing written' -and ($listed -join "`n") -ceq ($wantListed -join "`n") -and $listed -contains '.github/agents/packet-dispatcher.agent.md' -and $listed -contains '.github/hooks/packet-workflow.json' -and -not ($listed -match 'packet-board|packet-plan|packet-progress|check-scope')) 'it exits 1 and lists every file a downgrade would remove, and only those' $r.Text
    Assert-That ((Get-Snapshot $target) -ceq $before -and $r.Text -notmatch '(?m)^(add|update|remove)\s') 'every file under .github and the manifest stay byte-identical: nothing is removed' $r.Text
    $r = Invoke-Kit $installer @('-Target', $target, '-PlanOnly', '-DryRun')
    Assert-That ($r.Code -eq 1 -and (Get-Snapshot $target) -ceq $before) 'with -DryRun it is refused the same way' $r.Text
    # A manifest from before modes (0.1.x) has no mode: it reads as full.
    $man = Get-Manifest $target; $man.Remove('mode')
    [System.IO.File]::WriteAllText((Join-Path $target '.github/packet-workflow.kit.json'), ($man | ConvertTo-Json -Depth 5), $utf8)
    $before = Get-Snapshot $target
    $r = Invoke-Kit $installer @('-Target', $target, '-PlanOnly')
    Assert-That ($r.Code -eq 1 -and (Get-Snapshot $target) -ceq $before) 'a manifest without mode reads as full, and is refused too' $r.Text
    $r = Invoke-Kit $installer @('-Target', $target, '-DryRun')
    Assert-That ($r.Code -eq 0 -and $r.Text -notmatch 'makes the plan-only install full') 'and a plain run on it is an ordinary upgrade' $r.Text

    Write-Host '  downgrading by deleting the full install''s files first'
    foreach ($f in $wantListed) { Remove-Item -LiteralPath (Join-Path $target $f) }
    $r = Invoke-Kit $installer @('-Target', $target, '-PlanOnly', '-WithInstructions')
    $man = Get-Manifest $target
    $manFiles = @($man.files.Keys | Sort-Object { $_ } -Culture ([cultureinfo]::InvariantCulture))
    $b = Get-Block $target
    Assert-That ($r.Code -eq 0 -and $man.mode -ceq 'plan-only' -and ($manFiles -join "`n") -ceq ($wantSkills -join "`n") -and $r.Text -notmatch '(?m)^remove\s') 'once they are gone, -PlanOnly goes ahead, records plan-only and lists only its files' $r.Text
    Assert-That ($b.Count -eq 2 -and $b.Text.Contains($planTemplate) -and -not $b.Text.Contains($fullTemplate)) 'and its -WithInstructions puts the plan-only block back, still one block' $b.Text
    # Two blocks (a hand-made copy) become one.
    [System.IO.File]::WriteAllText((Join-Path $target '.github/copilot-instructions.md'), "$fullTemplate`n`nmine`n`n$fullTemplate`n", $utf8)
    $r = Invoke-Kit $installer @('-Target', $target, '-PlanOnly', '-WithInstructions')
    $b = Get-Block $target
    Assert-That ($b.Count -eq 2 -and $b.Text.Contains($planTemplate) -and $b.Text.Contains('mine')) 'a file with two marked blocks ends with one, this mode''s' $b.Text

    Write-Host '  plan, board and progress from a plan-only install'
    $caseRepo = New-CaseRepo
    Push-Location -LiteralPath $caseRepo
    try {
        # Only repo and the local board: no commands, models, guardrails, claims or review keys.
        [System.IO.File]::WriteAllText((Join-Path $caseRepo '.github/packet-workflow.json'), '{ "repo": "example/sample", "board": { "provider": "local" } }', $utf8)
        # The sample phase is invalid on purpose: PKT-05 is the suite's overlap and lock case, and PKT-02's
        # lock needs a locks key. Without both, it is a valid phase for a config this small.
        Remove-Item -LiteralPath (Join-Path $caseRepo 'docs/plan/phase-1/packets/PKT-05.md')
        $p2 = Join-Path $caseRepo 'docs/plan/phase-1/packets/PKT-02.md'
        [System.IO.File]::WriteAllText($p2, ((Get-Content -Raw $p2) -replace '(?m)^- \*\*Locks:\*\* migrations$', '- **Locks:** none'), $utf8)
        $p4 = Join-Path $caseRepo 'docs/plan/phase-1/packets/PKT-04.md'
        [System.IO.File]::WriteAllText($p4, ((Get-Content -Raw $p4) -replace '(?m)^- \*\*Review lenses:\*\* .*$', '- **Review lenses:** ux, performance, perfromance'), $utf8)
        & git add -A; & git commit -qm 'minimal config' | Out-Null
        $r = Invoke-Kit $installer @('-Target', $caseRepo, '-PlanOnly')
        & git add -A; & git commit -qm 'plan-only install' | Out-Null; & git push -q origin main 2>&1 | Out-Null
        $installedTree = @(Get-Tree (Join-Path $caseRepo '.github') | Where-Object { $_ -match '^(agents|hooks)/|^skills/packet-review/' })
        Assert-That ($r.Code -eq 0 -and $installedTree.Count -eq 0 -and -not (Test-Path '.github/skills/packet-review')) 'the install into a repository with a minimal config succeeds, with no review skill' $r.Text
        $gh = Join-Path $caseRepo '.github/skills'
        $validate = Join-Path $gh 'packet-plan/scripts/validate-packets.ps1'
        $board = Join-Path $gh 'packet-board/scripts/board.ps1'
        $r = Invoke-Kit $validate @('-Phase', 'phase-1')
        Assert-That ($r.Code -eq 0) 'validate-packets.ps1 exits 0 on the sample phase' $r.Text
        Assert-That ($r.Text -match "unknown review lens 'perfromance'" -and $r.Text -notmatch "unknown review lens '(performance|ux|security|correctness|data|architecture)'") 'with no lens folder next to it, it warns on perfromance and not on performance (the kit''s list)' $r.Text
        $fails = foreach ($cmd in @(@('setup'), @('sync', '-Phase', 'phase-1'), @('show'), @('next'), @('reconcile'))) {
            $r = Invoke-Kit $board $cmd
            if ($r.Code -ne 0) { "board $($cmd -join ' '): exit $($r.Code)`n$($r.Text)" }
        }
        Assert-That (-not $fails) 'board setup, sync, show, next and reconcile all exit 0' ($fails -join "`n")
        $r = Invoke-Kit (Join-Path $gh 'packet-progress/scripts/progress.ps1') @('-Json')
        $ok = $r.Code -eq 0; try { [void]($r.Text | ConvertFrom-Json) } catch { $ok = $false }
        Assert-That $ok 'progress.ps1 -Json exits 0 with JSON' $r.Text

        Write-Host '  check-scope.ps1 from a plan-only install'
        $scope = Join-Path $gh 'packet-dispatch/scripts/check-scope.ps1'
        & git switch -q -c case/inside
        New-Item -ItemType Directory -Force -Path (Join-Path $caseRepo 'src/Api') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $caseRepo 'src/Api/Orders.cs'), "class Orders {}`n", $utf8)
        & git add -A; & git commit -qm 'inside' | Out-Null
        $r = Invoke-Kit $scope @('-Packet', 'PKT-03', '-Base', 'origin/main')
        Assert-That ($r.Code -eq 0) 'it exits 0 on a branch inside its packet''s Owns' $r.Text
        & git switch -q -c case/outside
        New-Item -ItemType Directory -Force -Path (Join-Path $caseRepo 'src/Web') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $caseRepo 'src/Web/Page.cs'), "class Page {}`n", $utf8)
        & git add -A; & git commit -qm 'outside' | Out-Null
        $r = Invoke-Kit $scope @('-Packet', 'PKT-03', '-Base', 'origin/main')
        Assert-That ($r.Code -eq 1 -and $r.Text -match 'OUTSIDE.*src/Web/Page\.cs') 'and 1 on one that edits another packet''s path' $r.Text
        # A branch that edits its own copy of the script to print OK: its copy passes it, the pinned kit doesn't.
        & git switch -q case/inside
        & git switch -q -c case/forged
        [System.IO.File]::WriteAllText((Join-Path $caseRepo '.github/skills/packet-dispatch/scripts/check-scope.ps1'), "Write-Output 'OK'`nexit 0`n", $utf8)
        & git add -A; & git commit -qm 'forged check' | Out-Null
        $forged = Invoke-Kit $scope @('-Packet', 'PKT-03', '-Base', 'origin/main')
        & git switch -q main
        $zip = "$pinned.zip"
        & git archive --format=zip --output $zip origin/main .github/skills
        Expand-Archive -LiteralPath $zip -DestinationPath $pinned
        $r = Invoke-Kit (Join-Path $pinned '.github/skills/packet-dispatch/scripts/check-scope.ps1') @('-Packet', 'PKT-03', '-Base', 'origin/main', '-Head', 'case/forged')
        Assert-That ($forged.Code -eq 0 -and $forged.Text.Trim() -eq 'OK' -and $r.Code -eq 1 -and $r.Text -match 'MACHINERY.*check-scope\.ps1') 'run from a pinned kit with -Head, it still exits 1 when the branch edits its own check-scope.ps1 to print OK' "branch copy: $($forged.Code) $($forged.Text)`npinned: $($r.Text)"
    }
    finally { Pop-Location }

    Write-Host '  the docs for working without a dispatcher'
    $readme = Get-Content -Raw (Join-Path $kit 'README.md')
    $install = if ($readme -match '(?ms)^## Install\r?$(.*?)^## ') { $Matches[1] } else { '' }
    $quick = if ($readme -match '(?ms)^## Plan and board only\r?$(.*?)^## ') { $Matches[1] } else { '' }
    $quickLines = @($quick.Trim() -split '\r?\n').Count
    $quickWants = @('-PlanOnly', '`repo`', '`board.provider`', '/packet-plan', 'review and merge the plan PR', '/packet-board setup', '/packet-board sync', '**By hand:**', '**GitHub Issues or a GitHub Project:** assign the issue to Copilot', 'the issue body, which is the packet file', '**Azure Boards:**', '"Create a pull request with GitHub Copilot"', 'board set <ID> "Status=In progress"', '`board assign`', '`board ref`', 'the scope check', '`board reconcile`', 'no brief, no review panel and no claim', 'the scope check runs only when someone runs it', 'The owner reviews the PR, and branch protection is the merge gate', 'draw on the same AI credits, and the kit doesn''t estimate them')
    $quickMissing = @($quickWants | Where-Object { -not $quick.Contains($_) })
    Assert-That ($install.Contains('-PlanOnly') -and $quick -and $quickLines -le 30 -and $quickMissing.Count -eq 0) 'the README mentions -PlanOnly under Install, and its quick-start (at most 30 lines) gives the three hand-offs, the board commands and what a hand-off doesn''t do' "lines: $quickLines; missing: $($quickMissing -join ' | ')"
    $boardSkill = Get-Content -Raw (Join-Path $kit 'skills/packet-board/SKILL.md')
    $without = if ($boardSkill -match '(?ms)^## Without a dispatcher\r?$(.*?)^## ') { $Matches[1] } else { '' }
    $boardWants = @('board set <ID> "Status=In progress"', 'board assign <ID>', 'board ref <ID>', 'Preflight step 1', 'never from the PR branch''s copy', 'pwsh -File <temp>/packet-kit-<random>/.github/skills/packet-dispatch/scripts/check-scope.ps1 -Packet <ID> -Base origin/<default branch> -Head <PR branch>', 'board reconcile')
    $boardMissing = @($boardWants | Where-Object { -not $without.Contains($_) })
    Assert-That ($without -and $boardMissing.Count -eq 0) 'the board skill''s "Without a dispatcher" section gives set, assign, ref, the pinned scope check with -Head, and reconcile' ($boardMissing -join ' | ')
    $progressSkill = Get-Content -Raw (Join-Path $kit 'skills/packet-progress/SKILL.md')
    Assert-That ($progressSkill.Contains('`.github/skills/packet-dispatch/SKILL.md`') -and $progressSkill.Contains('never suggest it') -and $progressSkill -match '\*\*hand-off\*\*' -and $progressSkill -match 'stale In progress item there means \*\*asking the owner\*\*') 'the progress skill offers hand-offs, never /packet-dispatch, without the dispatch skill, and asks the owner about stale work' ''
}
finally {
    if ($caseRepo) { Remove-CaseRepo $caseRepo }
    foreach ($dir in $target, $models, $pinned, "$pinned.zip") { if ((Test-Path -LiteralPath $dir) -and -not $Keep) { Remove-Item -Recurse -Force -LiteralPath $dir } }
}
