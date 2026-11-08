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
    the ceiling                      budget.maxCreditsPerPacket there and on origin's default branch: the
                                     stricter of the two holds (an old base can't loosen it). Unset in
                                     both (budget isn't a table, no key, or null) prints OFF after
                                     reading only those two configs
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
           that must follow, the last round's confirmed lenses at its tier plus one (the +1 only up
           to review.tierCap, or 3; never below the last round's tier), in review.lensesPerReviewer lenses per run. After a round that passed
           (a CI fix), or after a Needs human (a fix the owner asked for): the fix run, which no
           marker books, plus a one-lens round at that round's tier
  A raise is the newest trusted PR comment `packet:budget max=<credits>`: it holds for the rest of the
  packet, and only ever raises the ceiling. A trusted raise whose max isn't a whole number above 0 is
  an error.

  credit-check.ps1 -Packet <ID> -Base <ref> [-Head HEAD] -Next start|round|fix [-Pr <n>]
                   [-Round <N> -Tier <t> -Lenses <a,b,c> -Runs <n>] [-Json]
  Prints OFF, or WITHIN|OVER so-far=<n> step=<n> total=<n> ceiling=<n> (config | config on
  origin/<default branch> | raised by <login> <date>).
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
    # Whole numbers, checked below: as [int], -Tier 2.5 would bind as 2 without a word.
    [string]$Round,
    [string]$Tier,
    [string]$Lenses,
    [string]$Runs,
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

function Invoke-CcQuiet([scriptblock]$Block) {
    <# Runs a config read with its warnings on stderr, so stdout stays the result line (or the JSON). #>
    & $Block 3>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.WarningRecord]) { [Console]::Error.WriteLine("credit-check: warning: $($_.Message)") } else { $_ }
    }
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
        foreach ($n in 'Round', 'Tier', 'Runs') {
            if ("$($PSBoundParameters[$n])" -notmatch '^\s*\d{1,6}\s*$') { Stop-Pw "-$n must be a whole number (got '$($PSBoundParameters[$n])')" }
        }
        # New names: the parameters stay [string], and would turn an [int] assigned to them back into one.
        $roundN = [int]$Round; $tierN = [int]$Tier; $runsN = [int]$Runs
        if ($roundN -lt 1) { Stop-Pw "-Round must be 1 or more (got $roundN)" }
        if ($tierN -lt 1 -or $tierN -gt 3) { Stop-Pw "-Tier must be 1, 2 or 3 (got $tierN)" }
        # As review-scope counts them: lower case, each once; a run name such as security+data is two.
        $lensList = @("$Lenses".ToLowerInvariant() -split '[,+\s]+' | Where-Object { $_ -and $_ -ne '-' } | Select-Object -Unique)
        if (-not $lensList.Count) { Stop-Pw '-Lenses must name at least one lens' }
        if ($runsN -lt 1 -or $runsN -gt $lensList.Count) { Stop-Pw "-Runs must be from 1 to the number of lenses ($($lensList.Count)) (got $runsN)" }
    }
    elseif ($roundArgs) { Stop-Pw "$($roundArgs -join ', ') only go with -Next round" }
    if ($Next -eq 'start' -and $Pr) { Stop-Pw '-Next start runs before the packet has a PR: leave out -Pr' }
    if ($Pr) {
        $Pr = $Pr.TrimStart('#')
        if ($Pr -notmatch '^\d+$') { Stop-Pw "-Pr must be a pull request number (got '$Pr')" }
    }

    # ---- The configs: at the base, and as merged on origin's default branch. With no ceiling in either,
    # that is all this reads.
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
    $cfg = Invoke-CcQuiet { Get-PwConfig -Ref $baseSha }
    # The default branch's config: who is trusted, and a second ceiling. The stricter of the two holds, so
    # an old merge base (from before a ceiling was set or lowered) can't loosen it. Read from git only.
    # Get-PwSharedConfig falls back to the working tree (the branch's checkout) without an origin, and
    # Get-PwConfig does when that branch has no config: both are errors here.
    $remoteRef = Get-PwDefaultRemoteRef
    if (-not $remoteRef) { Stop-Pw "no origin here, so origin's default branch, which decides who is trusted, can't be read" }
    & git -C $root cat-file -e "${remoteRef}:.github/packet-workflow.json" 2>$null
    if ($LASTEXITCODE -ne 0) { Stop-Pw "no .github/packet-workflow.json on $remoteRef, so who is trusted, and its ceiling, can't be read there" }
    $shared = Invoke-CcQuiet { Get-PwSharedConfig }
    # Get-PwCreditCeiling's rule for unset, read here so an install without a ceiling never reaches the
    # packet file, the PR or the rates.
    $isUnset = {
        param($c)
        $b = $c['budget']
        $b -isnot [System.Collections.IDictionary] -or -not $b.Contains('maxCreditsPerPacket') -or $null -eq $b['maxCreditsPerPacket']
    }
    $baseUnset = & $isUnset $cfg
    $sharedUnset = & $isUnset $shared
    if ($baseUnset -and $sharedUnset) {
        if ($Json) {
            # The same fields as WITHIN and OVER, so a reader that skips Result doesn't trip on a missing one.
            [pscustomobject]@{
                Result = 'OFF'; Packet = $Packet; Size = $null; Next = $Next; Pr = $null; Base = $baseSha
                SoFar = $null; Step = $null; Total = $null; Ceiling = $null; ConfigCeiling = $null
                PricedWith = $null; BaseTotal = $null; DefaultBranchTotal = $null
                CeilingFrom = $null; BaseCeiling = $null; DefaultBranchCeiling = $null
                Source = $null; RaisedBy = $null; RaisedAt = $null
            } | ConvertTo-Json
        }
        else { Write-Output "OFF (no budget.maxCreditsPerPacket at the base or on origin/$($shared.defaultBranch))" }
        exit 0
    }

    # ---- The packet, as the base has it and as origin's default branch has it.
    $pk = @(Get-PwPackets -Config $cfg -Ref $baseSha) | Where-Object { $_.Id -eq $Packet } | Select-Object -First 1
    if (-not $pk) { Stop-Pw "no packet file for $Packet at the base $($baseSha.Substring(0, 7))" }
    # On the default branch the packet may be gone (moved or renamed since the base): the base's then stands in.
    $pkShared = @(Get-PwPackets -Config $shared -Ref $remoteRef) | Where-Object { $_.Id -eq $Packet } | Select-Object -First 1
    if (-not $pkShared) { $pkShared = $pk }
    # Two views, each with its own config, size, ceiling and step: the base's, and the default branch's.
    # The check prices the packet in both and keeps the higher total (the owner's decision on #35), so an
    # old base can't lower the rates, the tier cap, the lens grouping or the size; and the stricter ceiling.
    $views = @(
        [pscustomobject]@{ Name = 'base'; Config = $cfg; Packet = $pk; Unset = $baseUnset; Where = "the base $($baseSha.Substring(0, 7))" },
        [pscustomobject]@{ Name = 'default-branch'; Config = $shared; Packet = $pkShared; Unset = $sharedUnset; Where = $remoteRef })
    foreach ($v in $views) {
        $sz = "$($v.Packet.Size)".ToUpperInvariant()
        if ($sz -notin 'S', 'M', 'L') { Stop-Pw "$Packet has no Size of S, M or L at $($v.Where) (got '$($v.Packet.Size)')" }
        $v | Add-Member -NotePropertyName Size -NotePropertyValue $sz
        # A ceiling that is set but broken stops the check, on either side.
        $v | Add-Member -NotePropertyName Ceiling -NotePropertyValue $(if ($v.Unset) { $null } else { Get-PwCreditCeiling -Config $v.Config -Size $sz })
    }
    $baseCeiling = $views[0].Ceiling
    $sharedCeiling = $views[1].Ceiling
    $ceilingFrom = 'base'
    $ceiling = $baseCeiling
    if ($null -eq $ceiling -or ($null -ne $sharedCeiling -and $sharedCeiling -lt $ceiling)) { $ceiling = $sharedCeiling; $ceilingFrom = 'default-branch' }

    # ---- The markers so far, and the step.
    $rows = @()
    $raise = $null
    $prNumber = $null
    if ($Next -ne 'start') {
        # Who is trusted comes from origin's default branch ($shared), never the base or the branch.
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
    if ($Next -eq 'round' -and $roundN -ne $lastRound + 1) { Stop-Pw "-Round $roundN isn't one more than the last round marker on PR #$prNumber (round $lastRound)" }
    if ($Next -eq 'fix') {
        if (-not $last) { Stop-Pw "-Next fix needs a round before it, and PR #$prNumber has no round marker" }
        $outcome = "$(Get-PwField $last 'Outcome')"
        if ($outcome -notin 'fix', 'pass', 'needs-human') { Stop-Pw "-Next fix after round $lastRound, whose outcome is '$outcome': only a fix, a passed round or a Needs human is followed by a fix run" }
    }
    $newStep = {
        <# The step's row, priced with one view's config (tier cap, lens grouping) and packet (Review tier). #>
        param($View)
        $per = [int]$View.Config.review.lensesPerReviewer
        $cap = if ($null -ne $View.Config.review.tierCap) { [int]$View.Config.review.tierCap } else { 3 }
        switch ($Next) {
            # Round 1 at tier 1, or at the packet's Review tier line, which review-scope raises round 1 to.
            'start' { [pscustomobject]@{ Kind = 'round'; Round = 1; Tier = $(if ("$($View.Packet.ReviewTier)" -match '^[1-4]$') { [string][Math]::Min(3, [int]$View.Packet.ReviewTier) } else { '1' }); Lenses = 'correctness'; Runs = '1'; Outcome = 'pass'; CreatedAt = $null } }
            'round' { [pscustomobject]@{ Kind = 'round'; Round = $roundN; Tier = [string]$tierN; Lenses = ($lensList -join ','); Runs = [string]$runsN; Outcome = 'pass'; CreatedAt = $null } }
            'fix' {
                $lastTier = Get-CcTier $last
                if ($outcome -eq 'fix') {
                    # The fix run is booked on that marker already: price the round that must follow it.
                    $confirmed = @("$(Get-PwField $last 'Confirmed')".ToLowerInvariant() -split '[,+\s]+' | Where-Object { $_ -and $_ -ne '-' } | Select-Object -Unique)
                    $n = [Math]::Max(1, $confirmed.Count)
                    # As review-scope carries it (PKT-3): never below the last round's tier; the cap holds back only the +1.
                    $tierNext = [Math]::Max($lastTier, [Math]::Min($lastTier + 1, $cap))
                    [pscustomobject]@{ Kind = 'round'; Round = $lastRound + 1; Tier = [string]$tierNext; Lenses = $(if ($confirmed) { $confirmed -join ',' } else { 'correctness' }); Runs = [string][Math]::Ceiling($n / $per); Outcome = 'pass'; CreatedAt = $null }
                }
                else {
                    # A CI fix after a passed round, or a fix the owner asked for after a Needs human: no marker
                    # books its run, so this row's outcome=fix does.
                    [pscustomobject]@{ Kind = 'round'; Round = $lastRound + 1; Tier = [string]$lastTier; Lenses = 'correctness'; Runs = '1'; Outcome = 'fix'; CreatedAt = $null }
                }
            }
        }
    }
    foreach ($v in $views) {
        $stepRow = & $newStep $v
        $vSoFar = if ($Next -eq 'start') { 0 } else { [double](Get-PwCreditEstimate -Config $v.Config -Size $v.Size -Rounds $rounds).Credits }
        $vTotal = [double](Get-PwCreditEstimate -Config $v.Config -Size $v.Size -Rounds (@($rounds) + @($stepRow))).Credits
        $v | Add-Member -NotePropertyName SoFar -NotePropertyValue $vSoFar
        $v | Add-Member -NotePropertyName Total -NotePropertyValue $vTotal
    }
    # The higher total; on a tie, the base's.
    $priced = if ($views[1].Total -gt $views[0].Total) { $views[1] } else { $views[0] }
    $size = $priced.Size
    $soFar = $priced.SoFar
    $total = $priced.Total
    $stepCredits = $total - $soFar

    # ---- A raise only ever raises the ceiling.
    $limit = $ceiling
    $source = if ($ceilingFrom -eq 'base') { 'config' } else { "config on origin/$($shared.defaultBranch)" }
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
            PricedWith = $priced.Name; BaseTotal = & $num $views[0].Total; DefaultBranchTotal = & $num $views[1].Total
            CeilingFrom = $ceilingFrom; BaseCeiling = $(if ($null -ne $baseCeiling) { & $num $baseCeiling } else { $null }); DefaultBranchCeiling = $(if ($null -ne $sharedCeiling) { & $num $sharedCeiling } else { $null })
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
