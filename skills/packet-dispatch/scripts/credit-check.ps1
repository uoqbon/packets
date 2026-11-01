#!/usr/bin/env pwsh
#Requires -Version 7.2
<#
.SYNOPSIS
  credit-check.ps1: do a packet's estimated credits so far, plus the next step, stay within its ceiling?

.DESCRIPTION
  Run before a claim (-Next start), a review round (-Next round) or a fix run (-Next fix). It prices the
  packet with Get-PwCreditEstimate, the estimator progress.ps1 -Credits uses, over the PR's round markers
  from trusted authors (Get-PwGhRounds), and compares the total with budget.maxCreditsPerPacket.

  What it reads, and from where:
    the config and the packet file   at the merge base of -Base and -Head, as review-scope does, so a
                                     branch can't raise its own ceiling or change its size or rates
    the ceiling                      budget.maxCreditsPerPacket there; unset (budget isn't a table, no
                                     key, or null) prints OFF after reading only that config
    who is trusted                   the GitHub sign-in and trustedAuthors in the config as merged on
                                     origin's default branch (Get-PwSharedConfig), as board rounds reads
                                     settles
    markers and raises               the PR's comments on GitHub, from those authors only; never the board.
                                     The PR is the packet's open one on a pkt/<id>- branch (-Pr is
                                     checked against that), and the base must have a config of its own
  It never posts anything.

  The step it prices:
    start  before a claim, with no PR: the base (dispatcher, first implementer run) plus a one-lens
           round at tier 1, so a ceiling no packet of this size can meet stops it before anything runs
    round  the round review-scope chose: -Round (one more than the last round marker), -Tier, -Lenses
           and -Runs
    fix    after a round with outcome=fix (whose marker already books the fix run): the cheapest round
           that must follow, the last round's confirmed lenses at its tier plus one (up to
           review.tierCap, or 3), in review.lensesPerReviewer lenses per run. After a round that passed
           (a CI fix): the fix run, which no marker books, plus a one-lens round at that round's tier
  A raise is the newest trusted PR comment `packet:budget max=<credits>`: it holds for the rest of the
  packet, and only ever raises the ceiling. A trusted raise whose max isn't a whole number above 0 is
  an error.

  credit-check.ps1 -Packet <ID> -Base <ref> [-Head HEAD] -Next start|round|fix [-Pr <n>]
                   [-Round <N> -Tier <t> -Lenses <a,b,c> -Runs <n>] [-Json]
  Prints OFF, or WITHIN|OVER so-far=<n> step=<n> total=<n> ceiling=<n> (config | raised by <login> <date>).
  Exit codes: 0 OFF or WITHIN · 3 OVER · any other code an error (stop; never a pass). An error the
  script finds exits 2; a parameter-binding error (pwsh -File) exits 1.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Packet,
    [string]$Base,
    [string]$Head = 'HEAD',
    [ValidateSet('start', 'round', 'fix')][string]$Next,
    [string]$Pr,
    [int]$Round = 0,
    [int]$Tier = 0,
    [string]$Lenses,
    [int]$Runs = 0,
    [switch]$Json
)

. "$PSScriptRoot/../../packet-board/scripts/PacketWorkflow.ps1"
# Rounds and raises live on the PR, so only the GitHub helpers load: never a board provider.
. "$PSScriptRoot/../../packet-board/scripts/providers/github-common.ps1"

function ConvertTo-CcUtcDay($At) {
    <# A comment's created_at as yyyy-MM-dd, UTC, whether the JSON reader gave a DateTime or a string. #>
    if ($null -eq $At) { return '' }
    $d = if ($At -is [DateTime]) { $At.ToUniversalTime() } elseif ($At -is [DateTimeOffset]) { $At.UtcDateTime } else { [DateTimeOffset]::Parse([string]$At, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
    $d.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-CcTier($Row) {
    <# A round marker's tier as the estimator prices it: 1 to 3, a tier=4 from before the merge as 3, none as 3. #>
    $t = "$(Get-PwField $Row 'Tier')"
    if ($t -match '^[1-4]$') { return [Math]::Min(3, [int]$t) }
    3
}

try {
    # ---- The arguments' shape, before anything is read: a caller's mistake shows even with no ceiling.
    if (-not $Packet) { Stop-Pw 'usage: -Packet <ID> is required' }
    if ($Packet -notmatch "^$script:IdPattern$") { Stop-Pw "-Packet must be a packet ID such as PKT-5 (got '$Packet')" }
    $Packet = $Packet.ToUpperInvariant()
    if (-not $Base) { Stop-Pw 'usage: -Base <ref> is required' }
    if (-not $Next) { Stop-Pw 'usage: -Next start|round|fix is required' }
    $roundArgs = @(foreach ($n in 'Round', 'Tier', 'Lenses', 'Runs') { if ($PSBoundParameters.ContainsKey($n)) { "-$n" } })
    $lensList = @()
    if ($Next -eq 'round') {
        $missing = @(foreach ($n in 'Round', 'Tier', 'Lenses', 'Runs') { if (-not $PSBoundParameters.ContainsKey($n)) { "-$n" } })
        if ($missing) { Stop-Pw "-Next round needs -Round, -Tier, -Lenses and -Runs (missing $($missing -join ', '))" }
        if ($Round -lt 1) { Stop-Pw "-Round must be 1 or more (got $Round)" }
        if ($Tier -lt 1 -or $Tier -gt 3) { Stop-Pw "-Tier must be 1, 2 or 3 (got $Tier)" }
        # As review-scope counts them: lower case, each once; a run name such as security+data is two.
        $lensList = @("$Lenses".ToLowerInvariant() -split '[,+\s]+' | Where-Object { $_ -and $_ -ne '-' } | Select-Object -Unique)
        if (-not $lensList.Count) { Stop-Pw '-Lenses must name at least one lens' }
        if ($Runs -lt 1 -or $Runs -gt $lensList.Count) { Stop-Pw "-Runs must be from 1 to the number of lenses ($($lensList.Count)) (got $Runs)" }
    }
    elseif ($roundArgs) { Stop-Pw "$($roundArgs -join ', ') only go with -Next round" }
    if ($Next -eq 'start' -and $Pr) { Stop-Pw '-Next start runs before the packet has a PR: leave out -Pr' }
    if ($Pr) {
        $Pr = $Pr.TrimStart('#')
        if ($Pr -notmatch '^\d+$') { Stop-Pw "-Pr must be a pull request number (got '$Pr')" }
    }

    # ---- The config at the base. With no ceiling, that is all this reads.
    $root = Get-RepoRoot
    foreach ($ref in $Base, $Head) {
        & git -C $root rev-parse --verify -q "$ref^{commit}" *> $null
        if ($LASTEXITCODE -ne 0) { Stop-Pw "'$ref' is not a commit here (fetch it first)" }
    }
    $baseSha = (Invoke-PwGit -C $root merge-base $Base $Head | Select-Object -First 1).Trim()
    # Get-PwConfig falls back to the working tree (the branch's checkout) when the base has no config: here
    # that would let a branch set its own ceiling, so a base without one is an error.
    & git -C $root cat-file -e "${baseSha}:.github/packet-workflow.json" 2>$null
    if ($LASTEXITCODE -ne 0) { Stop-Pw "no .github/packet-workflow.json at the base $($baseSha.Substring(0, 7)), so no ceiling can be read there" }
    $cfg = Get-PwConfig -Ref $baseSha
    # Get-PwCreditCeiling's rule for unset, read here so an install without a ceiling never reaches the
    # packet file, the PR or the rates.
    $budget = $cfg['budget']
    if ($budget -isnot [System.Collections.IDictionary] -or -not $budget.Contains('maxCreditsPerPacket') -or $null -eq $budget['maxCreditsPerPacket']) {
        if ($Json) { [pscustomobject]@{ Result = 'OFF'; Packet = $Packet; Next = $Next; Base = $baseSha } | ConvertTo-Json }
        else { Write-Output 'OFF (no budget.maxCreditsPerPacket at the base)' }
        exit 0
    }

    # ---- The packet's size, and its ceiling, at the base.
    $pk = @(Get-PwPackets -Config $cfg -Ref $baseSha) | Where-Object { $_.Id -eq $Packet } | Select-Object -First 1
    if (-not $pk) { Stop-Pw "no packet file for $Packet at the base $($baseSha.Substring(0, 7))" }
    $size = "$($pk.Size)".ToUpperInvariant()
    if ($size -notin 'S', 'M', 'L') { Stop-Pw "$Packet has no Size of S, M or L at the base (got '$($pk.Size)')" }
    $ceiling = Get-PwCreditCeiling -Config $cfg -Size $size

    # ---- The markers so far, and the step.
    $rows = @()
    $raise = $null
    $prNumber = $null
    if ($Next -ne 'start') {
        # Who is trusted comes from origin's default branch, never the base or the branch.
        $shared = Get-PwSharedConfig
        # The packet's own open PR: found by its pkt/<id>- branch, or, with -Pr, checked against it. Another
        # packet's PR, or an abandoned one, would price other markers and raises.
        $prefix = "pkt/$($Packet.ToLowerInvariant())-"
        $prNumber = $Pr
        if (-not $prNumber) {
            $found = Get-PwGhPrForPacket -Config $shared -PacketId $Packet -State open
            if (-not $found) { Stop-Pw "no open pull request for ${Packet}: pass -Pr, or use -Next start before the PR exists" }
            $prNumber = [string]$found.number
        }
        else {
            $pull = Invoke-PwGhJson api "repos/$($shared.repo)/pulls/$prNumber"
            $ref = if ($pull -and $pull['head']) { [string]$pull['head']['ref'] } else { '' }
            if (-not $ref.StartsWith($prefix)) { Stop-Pw "PR #$prNumber is on branch '$ref', not ${Packet}'s ($prefix…)" }
            if ([string]$pull['state'] -ne 'open') { Stop-Pw "PR #$prNumber is $($pull['state']), not open" }
        }
        # Get-PwGhRounds returns its list as one object: wrapping it in @() would nest it.
        $rows = Get-PwGhRounds -Config $shared -Pr $prNumber
        $raise = @($rows | Where-Object { $_.Kind -eq 'budget' }) | Select-Object -Last 1
    }
    $rounds = Get-PwRoundRows $rows
    $last = $rounds | Select-Object -Last 1
    $lastRound = if ($last) { [int](Get-PwField $last 'Round') } else { 0 }
    $per = [int]$cfg.review.lensesPerReviewer
    $cap = if ($null -ne $cfg.review.tierCap) { [int]$cfg.review.tierCap } else { 3 }
    $step = switch ($Next) {
        'start' { [pscustomobject]@{ Kind = 'round'; Round = 1; Tier = '1'; Lenses = 'correctness'; Runs = '1'; Outcome = 'pass'; CreatedAt = $null } }
        'round' {
            if ($Round -ne $lastRound + 1) { Stop-Pw "-Round $Round isn't one more than the last round marker on PR #$prNumber (round $lastRound)" }
            [pscustomobject]@{ Kind = 'round'; Round = $Round; Tier = [string]$Tier; Lenses = ($lensList -join ','); Runs = [string]$Runs; Outcome = 'pass'; CreatedAt = $null }
        }
        'fix' {
            if (-not $last) { Stop-Pw "-Next fix needs a round before it, and PR #$prNumber has no round marker" }
            $outcome = "$(Get-PwField $last 'Outcome')"
            $lastTier = Get-CcTier $last
            if ($outcome -eq 'fix') {
                # The fix run is booked on that marker already: price the round that must follow it.
                $confirmed = @("$(Get-PwField $last 'Confirmed')".ToLowerInvariant() -split '[,+\s]+' | Where-Object { $_ -and $_ -ne '-' } | Select-Object -Unique)
                $n = [Math]::Max(1, $confirmed.Count)
                $tierNext = [Math]::Min($lastTier + 1, $cap)
                [pscustomobject]@{ Kind = 'round'; Round = $lastRound + 1; Tier = [string]$tierNext; Lenses = $(if ($confirmed) { $confirmed -join ',' } else { 'correctness' }); Runs = [string][Math]::Ceiling($n / $per); Outcome = 'pass'; CreatedAt = $null }
            }
            elseif ($outcome -eq 'pass') {
                # A CI fix after a passed round: no marker books its run, so this row's outcome=fix does.
                [pscustomobject]@{ Kind = 'round'; Round = $lastRound + 1; Tier = [string][Math]::Min($lastTier, $cap); Lenses = 'correctness'; Runs = '1'; Outcome = 'fix'; CreatedAt = $null }
            }
            else { Stop-Pw "-Next fix after round $lastRound, whose outcome is '$outcome': only a fix or a passed round is followed by a fix run" }
        }
    }
    $soFar = if ($Next -eq 'start') { 0 } else { [double](Get-PwCreditEstimate -Config $cfg -Size $size -Rounds $rounds).Credits }
    $total = [double](Get-PwCreditEstimate -Config $cfg -Size $size -Rounds (@($rounds) + @($step))).Credits
    $stepCredits = $total - $soFar

    # ---- A raise only ever raises the ceiling.
    $limit = $ceiling
    $source = 'config'
    $raisedBy = $null; $raisedAt = $null
    if ($raise) {
        $max = "$(Get-PwField $raise 'Max')"
        if ($max -notmatch '^\d{1,9}$' -or [int]$max -le 0) { Stop-Pw "the raise by $($raise.Author) on PR #$prNumber ($($raise.Url)) must be packet:budget max=<a whole number above 0> (got max='$max')" }
        if ([double]$max -gt $ceiling) {
            $limit = [double]$max; $raisedBy = [string]$raise.Author; $raisedAt = ConvertTo-CcUtcDay $raise.CreatedAt
            $source = "raised by $raisedBy $raisedAt"
        }
    }
    $result = if ($total -le $limit) { 'WITHIN' } else { 'OVER' }
    if ($Json) {
        # Whole numbers as JSON integers, as the text line prints them.
        $num = { param([double]$v) if ($v -eq [Math]::Floor($v)) { [long]$v } else { $v } }
        $soFar = & $num $soFar; $stepCredits = & $num $stepCredits; $total = & $num $total; $limit = & $num $limit; $ceiling = & $num $ceiling
        [pscustomobject]@{
            Result = $result; Packet = $Packet; Size = $size; Next = $Next; Pr = $(if ($prNumber) { [int]$prNumber } else { $null }); Base = $baseSha
            SoFar = $soFar; Step = $stepCredits; Total = $total; Ceiling = $limit; ConfigCeiling = $ceiling
            Source = $(if ($raisedBy) { 'raised' } else { 'config' }); RaisedBy = $raisedBy; RaisedAt = $raisedAt
        } | ConvertTo-Json
    }
    else { Write-Output "$result so-far=$soFar step=$stepCredits total=$total ceiling=$limit ($source)" }
    if ($result -eq 'OVER') { exit 3 }
    exit 0
}
catch [PwError] {
    [Console]::Error.WriteLine("credit-check: $($_.Exception.Message)")
    exit 2
}
catch {
    [Console]::Error.WriteLine("credit-check: $($_.Exception.Message)")
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    exit 2
}
