#!/usr/bin/env pwsh
#Requires -Version 7.2
<#
.SYNOPSIS
  review-scope.ps1: the review tier and the lenses for one review round of a packet's diff.

.DESCRIPTION
  Tier (a floor: raise it with a reason, never lower it), measured on the whole diff <Base>...<Head>:
    1 light     no code files, or <= 50 lines in <= 3 files with no added control flow
    2 standard  ordinary code (the default)
    3 deep      the top tier: > 300 lines, > 8 files, >= 2 subsystems, a migration/schema, API contract,
                auth/secret, infra/CI path, concurrency in added lines, review machinery (agents, skills,
                hooks, prompts, instructions, workflows, the kit's config), a .gitattributes change, or a
                review.deepPaths or review.maxPaths match
  then raised by the packet's **Review tier** line, and for rounds 2+ by -PreviousTier (plus one with
  -FixedConfirmed, capped at 3). A tier 4 from before tiers 3 and 4 merged (a packet's line, a previous
  round's marker) counts as 3. Project raises are matched on both sides of a rename, before the
  ignore list (lockfiles, minified and generated output), so a project can always raise a path.

  Lenses:
    round 1 (no -Since)  the packet's Review lenses + the lenses whose review.lensPaths match a changed path
                         + concurrency when added lines match review.concurrencyPattern; never empty
    rounds 2+ (-Since)   the lenses that confirmed a finding last round (-Confirmed), plus, from what
                         changed since that round's head (first-parent commits, and each first-parent
                         merge: only the conflict resolution of a clean merge of the default branch):
                         every path-matched lens except correctness, tests and architecture; correctness
                         when > 50 code lines changed; tests when tests changed; architecture when a path
                         is outside the packet's Owns and touchpoints. A conflict resolution, or a merge of
                         anything but the default branch, adds every path-matched lens and correctness.
  The lenses come back in review.lensOrder (riskiest first). Runs groups them into reviewer runs of
  review.lensesPerReviewer lenses (neighbours in that order; 1 by default, so one lens per run), and
  Pairs groups the runs the panel starts together (review.maxParallelLenses at a time), each run
  written as its lenses joined with '+'. Grouping never drops a lens or changes the tier.

  review-scope.ps1 -Base <ref> [-Head <ref>] [-Packet <ID>] [-Since <prev head>] [-Confirmed a,b]
                   [-PreviousTier N] [-FixedConfirmed] [-Json]
  Exit codes: 0 chosen · 2 error (stop; never guess a tier) · 3 nothing changed against the base.
#>
param(
    [Parameter(Mandatory)][string]$Base,
    [string]$Head = 'HEAD',
    [string]$Packet,
    [string]$Since,
    [string[]]$Confirmed = @(),
    [ValidateRange(0, 4)][int]$PreviousTier = 0,
    [switch]$FixedConfirmed,
    [switch]$Json,
    [string]$ConfigPath
)

. "$PSScriptRoot/../../packet-board/scripts/PacketWorkflow.ps1"

$ignoreRe = '(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock|uv\.lock|Cargo\.lock|go\.sum|Gemfile\.lock|composer\.lock)$|\.(snap|min\.js|min\.css|map)$|(^|/)(dist|vendor|node_modules)/'
$docsRe = '\.(md|mdx|rst|txt|adoc)$|(^|/)(docs?|LICENSE|CHANGELOG|README)([./]|$)'
$testsRe = '(^|/)(tests?|__tests__|spec|specs|fixtures)/|(^|/)test_[^/]+$|_test\.[a-z]+$|\.(test|spec)\.[a-z]+$|(^|/)conftest\.py$'
$configRe = '\.(json|ya?ml|toml|ini|cfg|env|properties|editorconfig)$|(^|/)\.[^/]+rc$'
$machineryRe = '(^|/)\.github/(workflows|actions|agents|skills|prompts|instructions|copilot|hooks)/|(^|/)\.github/copilot-instructions\.md$|(^|/)AGENTS\.md$|(^|/)CLAUDE\.md$|(^|/)\.claude/|(^|/)\.agents/|(^|/)\.github/packet-lenses/|(^|/)\.github/packet-workflow\.json$'
$migrationRe = 'migrat|alembic|(^|/)schema|\.sql$|(^|/)prisma/|(^|/)db/'
$contractRe = 'openapi|swagger|\.proto$|\.graphql$|(^|/)types?\.(py|ts)$|\.d\.ts$|(^|/)contracts?/'
$authRe = 'auth|security|crypto|secret|token|password|permission|session|oauth|jwt|identity'
$infraRe = '(^|/)Dockerfile|docker-compose|terraform|\.tf$|\.bicep$|(^|/)helm/|k8s|kubernetes|nginx|(^|/)infra/|(^|/)deploy'
$mediaRe = '\.(png|jpe?g|gif|webp|avif|bmp|ico|icns|tiff?|heic|psd|pdf|zip|gz|tgz|bz2|xz|zst|7z|rar|tar|woff2?|ttf|otf|eot|mp[34]|m4a|wav|flac|ogg|webm|mov|avi|docx|xlsx|pptx)$'
$controlRe = '\b(if|elif|else|for|foreach|while|switch|case|match|try|catch|except|finally|when|unless)\b'
# The tier's concurrency check is review-tier.sh's, case for case; review.concurrencyPattern can only add to it.
$tierConcurrencyRe = '\b(async|await|Thread|thread|mutex|Mutex|RLock|goroutine|go func|Promise\.all|asyncio|channel|semaphore|atomic)\b|\bLock\(|\bselect \{'
# The concurrency lens's default when the config sets no review.concurrencyPattern.
$defaultConcurrencyRe = '\b(async|await|Thread|Mutex|lock|SemaphoreSlim|Interlocked|ConcurrentDictionary|Task\.WhenAll|Parallel\.|Promise\.all|asyncio|goroutine|go func|sync\.Mutex|atomic|Channel<)\b'
$tierNames = @{ 1 = 'light'; 2 = 'standard'; 3 = 'deep' }

function Test-Re([string]$Text, [string]$Pattern, [switch]$IgnoreCase) {
    if (-not $Pattern -or -not $Text) { return $false }
    $opts = if ($IgnoreCase) { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase } else { [System.Text.RegularExpressions.RegexOptions]::None }
    [regex]::IsMatch($Text, $Pattern, $opts)
}

function Get-Numstat([string]$From, [string]$To, [switch]$ThreeDot) {
    $range = if ($ThreeDot) { "$From...$To" } else { "$From..$To" }
    $raw = (Invoke-PwGit -C $script:root diff --numstat -z --find-renames --no-color --no-ext-diff $range) -join "`n"
    $tokens = @($raw -split "`0")
    $rows = [System.Collections.Generic.List[object]]::new()
    $i = 0
    while ($i -lt $tokens.Count) {
        $t = $tokens[$i].TrimStart("`n"); $i++
        if (-not $t) { continue }
        $parts = $t -split "`t", 3
        if ($parts.Count -lt 3) { continue }
        $old = $null; $path = $parts[2]
        if (-not $path) { $old = $tokens[$i]; $path = $tokens[$i + 1]; $i += 2 }
        $rows.Add([pscustomobject]@{ Add = $parts[0]; Del = $parts[1]; Path = $path; Old = $old })
    }
    , $rows
}

function Get-AddedLines([string]$Range) {
    @(Invoke-PwGit -C $script:root diff -U0 --no-color --no-ext-diff $Range | Where-Object { $_ -match '^\+' -and $_ -notmatch '^\+\+\+ ' })
}

function Get-PathLenses([string[]]$Paths, [string[]]$Added) {
    $set = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($path in $Paths) {
        foreach ($lens in @($script:cfg.review.lensPaths.Keys)) {
            if (Test-Re $path $script:cfg.review.lensPaths[$lens]) { [void]$set.Add($lens) }
        }
    }
    $conc = if ($script:cfg.review.concurrencyPattern) { $script:cfg.review.concurrencyPattern } else { $defaultConcurrencyRe }
    if ($Added | Where-Object { Test-Re $_ $conc }) { [void]$set.Add('concurrency') }
    , $set
}

function Get-NativeBytes([string[]]$GitArgs) {
    # git's raw stdout as bytes: PowerShell would decode it as text and lose NULs.
    $psi = [System.Diagnostics.ProcessStartInfo]::new('git')
    foreach ($a in @('-C', $script:root) + $GitArgs) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $errTask = $proc.StandardError.ReadToEndAsync()
    $ms = [System.IO.MemoryStream]::new()
    $proc.StandardOutput.BaseStream.CopyTo($ms)
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { Stop-Pw "git $($GitArgs -join ' ') failed: $($errTask.Result.Trim())" }
    , $ms.ToArray()
}

function Test-Utf16ish([byte[]]$Bytes) {
    # review-tier.sh's test: at least 4 NULs and 0.1% of the first 64 KB, 90% of them on one byte parity.
    if (-not $Bytes) { return $false }
    $n = [Math]::Min($Bytes.Length, 65536); $nul = 0; $odd = 0
    for ($i = 0; $i -lt $n; $i++) { if ($Bytes[$i] -eq 0) { $nul++; if ($i % 2) { $odd++ } } }
    $nul -ge 4 -and $nul * 1000 -ge $n -and ($odd * 10 -ge $nul * 9 -or ($nul - $odd) * 10 -ge $nul * 9)
}

function Read-OpaqueDiff($Row, [string]$Range, [string]$BaseSha, [string]$HeadSha) {
    <# A file git calls binary but that has no media extension (one NUL, or UTF-16 source): read its
       diff as text with NULs dropped, as review-tier.sh does, so a NUL can't hide its lines. Returns
       @{ Junk; Add; Del; Added } where Junk means the bytes look random and weren't counted. #>
    $sides = @($Row.Path) + $(if ($Row.Old) { @($Row.Old) } else { @() })
    $bytes = Get-NativeBytes (@('diff', '--text', '-U0', '--no-color', '--no-ext-diff', $Range, '--') + @($sides | ForEach-Object { ":(literal)$_" }))
    $clean = [System.Collections.Generic.List[byte]]::new($bytes.Length)
    $ctrl = 0
    foreach ($b in $bytes) {
        if ($b -eq 0) { continue }
        $clean.Add($b)
        if (($b -lt 32 -and $b -notin 9, 10, 12, 13) -or $b -eq 127) { $ctrl++ }
    }
    $utf16 = $false
    foreach ($spec in @("${HeadSha}:$($Row.Path)", "${BaseSha}:$(if ($Row.Old) { $Row.Old } else { $Row.Path })")) {
        try { if (Test-Utf16ish (Get-NativeBytes @('cat-file', 'blob', $spec))) { $utf16 = $true; break } } catch { }
    }
    if ($ctrl * 20 -gt $clean.Count -and -not $utf16) { return @{ Junk = $true; Add = 0; Del = 0; Added = @() } }
    $text = [System.Text.Encoding]::UTF8.GetString($clean.ToArray())
    $add = 0; $del = 0; $addedLines = [System.Collections.Generic.List[string]]::new()
    $inHunk = $false
    foreach ($line in ($text -split "`n")) {
        if ($line.StartsWith('diff --git ')) { $inHunk = $false; continue }
        if ($line.StartsWith('@@')) { $inHunk = $true; continue }
        if (-not $inHunk) { continue }
        if ($line.StartsWith('+')) { $add++; $addedLines.Add($line) } elseif ($line.StartsWith('-')) { $del++ }
    }
    @{ Junk = $false; Add = $add; Del = $del; Added = @($addedLines) }
}

function Test-MergeOfDefault([string]$Merge) {
    $parents = @(((Invoke-PwGit -C $script:root rev-list --parents -n 1 $Merge) -join ' ') -split '\s+' | Select-Object -Skip 1)
    if ($parents.Count -ne 2) { return $false }
    $main = "origin/$($script:cfg.defaultBranch)"
    & git -C $script:root rev-parse --verify -q "$main^{commit}" *> $null
    if ($LASTEXITCODE -ne 0) { $main = $script:cfg.defaultBranch }
    & git -C $script:root merge-base --is-ancestor $parents[1] $main *> $null
    $LASTEXITCODE -eq 0
}

try {
    $script:root = Get-RepoRoot
    foreach ($ref in @($Base, $Head) + $(if ($Since) { @($Since) } else { @() })) {
        & git -C $root rev-parse --verify -q "$ref^{commit}" *> $null
        if ($LASTEXITCODE -ne 0) { Stop-Pw "'$ref' is not a commit here (fetch it first)" }
    }
    $headSha = (Invoke-PwGit -C $root rev-parse $Head | Select-Object -First 1).Trim()
    $baseSha = (Invoke-PwGit -C $root merge-base $Base $Head | Select-Object -First 1).Trim()
    # The config as it is at the base: a branch can't change its own tier raises or lens rules.
    $script:cfg = Get-PwConfig -Path $ConfigPath -Ref $(if ($ConfigPath) { '' } else { $baseSha })
    # The project's lens directory (paths.lenses) is review machinery wherever it is configured.
    $lensDir = ConvertTo-PwRepoPath $cfg.paths.lenses
    if ($lensDir) { $machineryRe += '|^' + [regex]::Escape($lensDir) + '/' }
    # -Confirmed arrives as one string under pwsh -File ("security,data"); the panel passes "-" when the previous
    # round passed (with nothing confirmed, or with should-fix findings it left to follow-ups).
    $Confirmed = @($Confirmed | ForEach-Object { "$_" -split '[,\s]+' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ -and $_ -ne '-' })
    $pk = $null
    if ($Packet) {
        # The packet as it was at the base: a packet branch can't widen its own Owns or lower its tier.
        $pk = @(Get-PwPackets -Config $cfg -Ref $baseSha) | Where-Object { $_.Id -eq $Packet.ToUpperInvariant() } | Select-Object -First 1
        if (-not $pk) { Stop-Pw "no packet file for $Packet at the base $($baseSha.Substring(0, 7))" }
    }

    # ---- Tier, over the whole diff.
    $rows = Get-Numstat $Base $Head -ThreeDot
    if ($rows.Count -eq 0) {
        if ($Json) { [pscustomobject]@{ Tier = $null; Reason = 'no diff' } | ConvertTo-Json } else { Write-Output "NO DIFF: nothing changed between $Base and $Head" }
        exit 3
    }
    $files = 0; $lines = 0; $code = 0; $docs = 0; $tests = 0; $config = 0; $ignored = 0
    $subsystems = [System.Collections.Generic.HashSet[string]]::new()
    $flags = [ordered]@{}
    $docsPaths = [System.Collections.Generic.List[string]]::new()
    $opaqueAdded = [System.Collections.Generic.List[string]]::new()
    $opaqueNonDocs = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $rows) {
        $sides = @($r.Path) + $(if ($r.Old) { @($r.Old) } else { @() })
        $hitMax = $sides | Where-Object { Test-Re $_ $cfg.review.maxPaths } | Select-Object -First 1
        $hitDeep = $sides | Where-Object { Test-Re $_ $cfg.review.deepPaths } | Select-Object -First 1
        if ($hitMax -and -not $flags.Contains('max')) { $flags['max'] = "project critical path: $hitMax" }
        if ($hitDeep -and -not $flags.Contains('deep')) { $flags['deep'] = "project deep path: $hitDeep" }
        if (-not $hitMax -and -not $hitDeep -and -not ($sides | Where-Object { -not (Test-Re $_ $ignoreRe) })) { $ignored++; continue }
        $files++
        $class = 'docs'
        foreach ($p in $sides) {
            $c = if (Test-Re $p $docsRe) { 'docs' } elseif (Test-Re $p $testsRe) { 'tests' } elseif (Test-Re $p $configRe) { 'config' } else { 'code' }
            $rank = @{ docs = 0; config = 1; tests = 2; code = 3 }
            if ($rank[$c] -gt $rank[$class]) { $class = $c }
        }
        if ($r.Add -eq '-' -or $r.Del -eq '-') {
            # A real media file keeps 0 lines; anything else git calls binary is read with its NULs dropped.
            if (@($sides | Where-Object { -not (Test-Re $_ $mediaRe -IgnoreCase) }).Count) {
                $o = Read-OpaqueDiff $r "$Base...$Head" $baseSha $headSha
                if ($o.Junk) {
                    if ($class -ne 'docs' -and -not $flags.Contains('junk')) { $flags['junk'] = "binary-looking file without a media extension, read as random bytes, lines not counted: $($r.Path)" }
                }
                else {
                    $lines += $o.Add + $o.Del
                    foreach ($l in $o.Added) { $opaqueAdded.Add($l); if ($class -ne 'docs') { $opaqueNonDocs.Add($l) } }
                    if ($class -ne 'docs' -and -not $flags.Contains('opaque')) { $flags['opaque'] = "binary-looking file read as text with NULs dropped (sizes are a guess): $($r.Path)" }
                }
            }
        }
        else { $lines += [int]$r.Add + [int]$r.Del }
        switch ($class) {
            'docs' { $docs++; $docsPaths.Add($r.Path) }
            'tests' { $tests++ }
            'config' { $config++ }
            'code' {
                $code++
                foreach ($p in $sides) {
                    $seg = $p -split '/'
                    [void]$subsystems.Add($(if ($seg.Count -ge 3) { "$($seg[0])/$($seg[1])" } elseif ($seg.Count -eq 2) { $seg[0] } else { '.' }))
                }
            }
        }
        foreach ($p in $sides) {
            if (-not $flags.Contains('machinery') -and (Test-Re $p $machineryRe)) { $flags['machinery'] = "review machinery path: $p" }
            if (-not $flags.Contains('attributes') -and (Test-Re $p '(^|/)\.gitattributes$' -IgnoreCase)) { $flags['attributes'] = "attributes file changed, so line counts may be wrong: $p" }
            if (-not $flags.Contains('migration') -and (Test-Re $p $migrationRe -IgnoreCase)) { $flags['migration'] = "migration/schema path: $p" }
            if (-not $flags.Contains('contract') -and (Test-Re $p $contractRe -IgnoreCase)) { $flags['contract'] = "API contract path: $p" }
            if (-not $flags.Contains('auth') -and (Test-Re $p $authRe -IgnoreCase)) { $flags['auth'] = "auth/security path: $p" }
            if (-not $flags.Contains('infra') -and (Test-Re $p $infraRe -IgnoreCase)) { $flags['infra'] = "infra/CI path: $p" }
        }
    }
    if ($files -eq 0) {
        $tier = 3; $reasons = [System.Collections.Generic.List[string]]@("only ignored files ($ignored) changed; generated output still gets a deep look")
    }
    else {
        $range = "$Base...$Head"
        $added = @(Get-AddedLines $range) + @($opaqueAdded)
        $controlAdded = @($added | Where-Object { Test-Re $_ $controlRe }).Count
        $concHit = $added | Where-Object { (Test-Re $_ $tierConcurrencyRe) -or (Test-Re $_ $cfg.review.concurrencyPattern) } | Select-Object -First 1
        $reasons = [System.Collections.Generic.List[string]]::new()
        $tier = 2
        if ($code -eq 0) {
            if ($tests -eq 0 -and $config -eq 0) { $tier = 1; $reasons.Add("docs only ($docs files)") }
            elseif ($lines -le 50 -and $files -le 3) {
                $nonDocs = if ($docsPaths.Count) { @(Invoke-PwGit -C $root diff -U0 --no-color --no-ext-diff $range . @($docsPaths | ForEach-Object { ":(exclude,literal)$_" }) | Where-Object { $_ -match '^\+' -and $_ -notmatch '^\+\+\+ ' }) + @($opaqueNonDocs) } else { $added }
                $controlNonDocs = @($nonDocs | Where-Object { Test-Re $_ $controlRe }).Count
                if ($controlNonDocs -eq 0) { $tier = 1; $reasons.Add("no code files; $lines lines in $files files, no added control flow") }
                else { $reasons.Add("tests/config only but $controlNonDocs added control-flow lines") }
            }
            else { $reasons.Add("no code files but $lines lines in $files files (tests $tests, config $config)") }
        }
        elseif ($lines -le 50 -and $files -le 3 -and $controlAdded -eq 0) { $tier = 1; $reasons.Add("$lines lines in $files files, no added control flow") }
        else { $reasons.Add("code change: $lines lines in $files files, $controlAdded added control-flow lines") }

        $raise = { param($t, $why) if ($script:tierNow -lt $t) { $script:tierNow = $t }; $reasons.Add($why) }
        $script:tierNow = $tier
        if ($flags.Contains('opaque')) { & $raise 2 $flags['opaque'] }
        if ($flags.Contains('junk')) { & $raise 2 $flags['junk'] }
        if ($lines -gt 300) { & $raise 3 "$lines lines > 300" }
        if ($files -gt 8) { & $raise 3 "$files files > 8" }
        if ($subsystems.Count -ge 2) { & $raise 3 "$($subsystems.Count) subsystems touched: $(@($subsystems) -join ' ')" }
        foreach ($k in 'migration', 'contract', 'auth', 'infra', 'deep') { if ($flags.Contains($k)) { & $raise 3 $flags[$k] } }
        if ($concHit) { & $raise 3 "concurrency in added lines: $($concHit.Substring(0, [Math]::Min(80, $concHit.Length)).Trim())" }
        foreach ($k in 'machinery', 'attributes', 'max') { if ($flags.Contains($k)) { & $raise 3 $flags[$k] } }
        $tier = $script:tierNow
    }
    $floor = $tier
    if ($pk -and $pk.ReviewTier -and [Math]::Min(3, [int]$pk.ReviewTier) -gt $tier) { $tier = [Math]::Min(3, [int]$pk.ReviewTier); $reasons.Add("raised to $tier by $($pk.Id)'s Review tier line") }
    if ($PreviousTier -gt 0) {
        $carry = [Math]::Min(3, $PreviousTier + $(if ($FixedConfirmed) { 1 } else { 0 }))
        if ($carry -gt $tier) { $tier = $carry; $reasons.Add("raised to ${tier}: the previous round ran at $PreviousTier$(if ($FixedConfirmed) { ', and its confirmed findings were fixed (+1)' })") }
    }

    # ---- Lenses.
    $lenses = [System.Collections.Generic.HashSet[string]]::new()
    $lensWhy = [System.Collections.Generic.List[string]]::new()
    if (-not $Since) {
        if ($pk) { foreach ($l in $pk.Lenses) { [void]$lenses.Add($l) }; if ($pk.Lenses) { $lensWhy.Add("packet lenses: $($pk.Lenses -join ', ')") } }
        $allPaths = @($rows | ForEach-Object { $_.Path; if ($_.Old) { $_.Old } })
        $fromPaths = Get-PathLenses $allPaths (Get-AddedLines "$Base...$Head")
        $extra = @($fromPaths | Where-Object { -not $lenses.Contains($_) })
        foreach ($l in $fromPaths) { [void]$lenses.Add($l) }
        if ($extra) { $lensWhy.Add("added by the diff's paths: $($extra -join ', ')") }
    }
    else {
        foreach ($l in $Confirmed) { if ($l) { [void]$lenses.Add($l.Trim().ToLowerInvariant()) } }
        if ($Confirmed) { $lensWhy.Add("confirmed findings last round: $($Confirmed -join ', ')") }
        $changed = [System.Collections.Generic.List[string]]::new()
        $addedSince = [System.Collections.Generic.List[string]]::new()
        $alwaysReview = $false
        $codeLinesSince = 0
        foreach ($c in @(Invoke-PwGit -C $root rev-list --first-parent --no-merges "$Since..$Head" | Where-Object { $_ })) {
            foreach ($row in (Get-Numstat "$c~1" $c)) {
                $changed.Add($row.Path); if ($row.Old) { $changed.Add($row.Old) }
                if ($row.Add -ne '-' -and -not (Test-Re $row.Path $docsRe) -and -not (Test-Re $row.Path $testsRe)) { $codeLinesSince += [int]$row.Add + [int]$row.Del }
            }
            foreach ($l in (Get-AddedLines "$c~1..$c")) { $addedSince.Add($l) }
        }
        foreach ($m in @(Invoke-PwGit -C $root rev-list --first-parent --merges "$Since..$Head" | Where-Object { $_ })) {
            if (Test-MergeOfDefault $m) {
                $resolution = @(Invoke-PwGit -C $root show --remerge-diff --format= --name-only $m | Where-Object { $_ })
                if ($resolution.Count) { $alwaysReview = $true; foreach ($p in $resolution) { $changed.Add($p) }; $lensWhy.Add("merge $($m.Substring(0, 7)) resolved conflicts") }
            }
            else {
                $alwaysReview = $true
                foreach ($p in @(Invoke-PwGit -C $root diff --name-only "$m^1" $m | Where-Object { $_ })) { $changed.Add($p) }
                foreach ($l in (Get-AddedLines "$m^1..$m")) { $addedSince.Add($l) }
                $lensWhy.Add("merge $($m.Substring(0, 7)) brings in code no panel saw")
            }
        }
        $fromPaths = Get-PathLenses @($changed) @($addedSince)
        foreach ($l in $fromPaths) {
            if ($alwaysReview -or $l -notin 'correctness', 'tests', 'architecture') { [void]$lenses.Add($l) }
        }
        if ($alwaysReview) { [void]$lenses.Add('correctness') }
        if ($codeLinesSince -gt 50) { [void]$lenses.Add('correctness'); $lensWhy.Add("$codeLinesSince code lines changed since $($Since.Substring(0, [Math]::Min(7, $Since.Length)))") }
        if ($changed | Where-Object { Test-Re $_ $testsRe }) { [void]$lenses.Add('tests') }
        if ($pk) {
            $decision = $cfg.paths.decisions.Replace('{phase}', $pk.Phase).Replace('{packet}', $pk.Id)
            $outside = @($changed | Where-Object { $_ -ne $decision -and -not (Test-PwPacketOwnsPath -Packet $pk -Path $_) })
            if ($outside) { [void]$lenses.Add('architecture'); $lensWhy.Add("paths outside $($pk.Id)'s Owns: $($outside[0])") }
        }
    }
    if ($lenses.Count -eq 0) { [void]$lenses.Add('correctness'); $lensWhy.Add('a round never runs with no lens') }
    $order = @($cfg.review.lensOrder)
    $ordered = @($lenses | Sort-Object { $i = [array]::IndexOf($order, $_); if ($i -lt 0) { 999 } else { $i } }, { $_ })

    $agent = $cfg.review.agents[[string]$tier]
    # A project's own tier-4 reviewer (from before tiers 3 and 4 merged) runs tier 3, so its critical paths
    # never go to a weaker agent; the old template's packet-reviewer-max is gone and is ignored.
    $legacyMax = $cfg.review.agents['4']
    if ($tier -eq 3 -and $legacyMax -is [string] -and $legacyMax.Trim() -and $legacyMax.Trim() -ne 'packet-reviewer-max') {
        $agent = $legacyMax.Trim()
        $reasons.Add("review.agents.4 ($agent) runs tier 3: tiers 3 and 4 merged, so move it to review.agents.3")
    }
    # Reviewer runs: review.lensesPerReviewer lenses each, neighbours in lensOrder. Pairs: the runs started
    # together (review.maxParallelLenses at a time), each run written as its lenses joined with '+'.
    $per = [int]$cfg.review.lensesPerReviewer
    $par = [int]$cfg.review.maxParallelLenses
    $runs = @(for ($i = 0; $i -lt $ordered.Count; $i += $per) { , @($ordered[$i..([Math]::Min($i + $per, $ordered.Count) - 1)]) })
    $runNames = @($runs | ForEach-Object { $_ -join '+' })
    $result = [pscustomobject]@{
        Tier = $tier; Name = $tierNames[$tier]; Agent = $agent; Floor = $floor
        Base = $baseSha.Substring(0, 12); Head = $headSha.Substring(0, 12); HeadSha = $headSha; BaseSha = $baseSha
        Files = $files; Lines = $lines
        Breakdown = [ordered]@{ code = $code; tests = $tests; docs = $docs; config = $config; ignored = $ignored }
        Reasons = @($reasons)
        Lenses = $ordered; LensReasons = @($lensWhy)
        Runs = $runs
        Pairs = @(for ($i = 0; $i -lt $runNames.Count; $i += $par) { , @($runNames[$i..([Math]::Min($i + $par, $runNames.Count) - 1)]) })
        # The panel's limits, from the config at the base like everything above: never the checkout's copy.
        Settings = [ordered]@{
            MaxRounds = [int]$cfg.review.maxRounds; ShouldFixPassFromRound = [int]$cfg.review.shouldFixPassFromRound
            MaxParallelLenses = $par; LensesPerReviewer = $per
        }
    }
    if ($Json) { $result | ConvertTo-Json -Depth 6 }
    else {
        Write-Output "TIER=$tier ($($tierNames[$tier])) AGENT=$agent FLOOR=$floor"
        Write-Output "BASE=$($result.Base) HEAD=$($result.Head) FILES=$files LINES=$lines (code $code, tests $tests, docs $docs, config $config, ignored $ignored)"
        Write-Output 'REASONS (a floor: raise it with a reason, never lower it):'
        foreach ($r in $reasons) { Write-Output "  - $r" }
        Write-Output "LENSES=$($ordered -join ',')"
        foreach ($r in $lensWhy) { Write-Output "  - $r" }
        if ($per -gt 1) { Write-Output "RUNS=$($runNames -join ',') ($($runs.Count) reviewer runs, up to $per lenses each)" }
        Write-Output "SETTINGS=maxRounds $($result.Settings.MaxRounds), should-fix-only rounds pass from round $($result.Settings.ShouldFixPassFromRound), $par reviewer runs at a time, $per lens(es) per run"
    }
}
catch [PwError] {
    [Console]::Error.WriteLine("review-scope: $($_.Exception.Message)")
    exit 2
}
catch {
    [Console]::Error.WriteLine("review-scope: $($_.Exception.Message)")
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    exit 2
}
