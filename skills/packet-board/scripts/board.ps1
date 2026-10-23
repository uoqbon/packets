#!/usr/bin/env pwsh
#Requires -Version 7.2
<#
.SYNOPSIS
  board.ps1: read and update the packet board (GitHub Project, GitHub issues or Azure Boards).

.DESCRIPTION
  Every packet skill goes through this script, so all of them see one board the same way. The provider
  comes from .github/packet-workflow.json (board.provider) as merged on origin/<defaultBranch>, so a
  branch checked out here can't change who is trusted or which board is written. Packets are read from the packet files under
  paths.plans; by default the read commands use what is merged (origin/<defaultBranch>) and sync uses
  the working tree. -WorkingTree or -Ref <commit> overrides either. A dependency whose ID prefix the
  config's remotes lists is another repository's packet: next and deps read its issue there (Done once it
  is closed as completed), listing each such repository's packet issues once per call.

  board.ps1 setup [-DryRun]                 create the labels/fields the board needs; report what it can't create
  board.ps1 sync [-Phase p] [-DryRun] [-Force]
                                            create or update one item per packet file, linked under the
                                            plan's root item; never touches Status. -Force: the files win
                                            over board edits (bodies, and an item's parent)
  board.ps1 show [-Phase p] [-Json]         every packet and human task with its board state
  board.ps1 next [-Phase p] [-Json]         Ready packets in dispatch order (priority, wave, id) with verdicts
  board.ps1 deps <ID> [-Json]               one packet's verdict: START, STACK or BLOCKED, with reasons
  board.ps1 get <ID>                        the item as JSON
  board.ps1 set <ID> Field=Value …          Status, Priority, Size, Wave, Target (Status: one of the seven)
  board.ps1 new-claim-id                    a fresh claim id for this session
  board.ps1 claim <ID> <claim-id> [-Force]  the claim check: HOLD (exit 0) or LOST (exit 1). Posts a claim
                                            comment only when one is due (none yet, or a third of the lease
                                            gone, by the board's clock); otherwise checks without writing.
                                            The line ends with (renewed; …) or (kept, nothing posted; …) and
                                            the lease left. -Force: post a renewal now
  board.ps1 release <ID> <claim-id>         delete this claim id's claim comments
  board.ps1 claims <ID>                     claims from the last lease window, by the board's clock (report only)
  board.ps1 comment <ID> <file>             post the file as a comment on the item
  board.ps1 marker <ID> <kind> [-Json]      the newest trusted comment on the item with a `packet:<kind>` marker
  board.ps1 comments <ID> [-Json]           the item's comments from trusted authors (the owner's answers)
  board.ps1 assign <ID>                     assign the item to the signed-in user
  board.ps1 ref <ID>                        the PR-body line that links and closes the item
  board.ps1 pr <ID> [-Json]                 the packet's newest pull request (open first)
  board.ps1 rounds <PR> [-Json]             round reports, settle requests and settle checks on a PR, oldest first
                                            (trusted authors only: the signed-in user and trustedAuthors)
  board.ps1 locks <ID>                      open PRs (other than the packet's own) touching its locks; exit 1 if any
  board.ps1 reconcile [-DryRun]             closed items -> Done; report items with no packet file

  Exit codes: 0 done (HOLD, START/STACK) · 1 a negative answer (LOST, BLOCKED, problems, lock taken) ·
  2 an error (bad arguments, config, a failed call). A failed call is never a positive answer.
#>
param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$Rest = @(),
    [string]$Phase,
    [string]$Ref,
    [switch]$WorkingTree,
    [switch]$Json,
    [switch]$DryRun,
    [switch]$Force,
    [string]$ConfigPath
)

. "$PSScriptRoot/PacketWorkflow.ps1"

function Write-PwJson { param($Value) ConvertTo-Json -InputObject $Value -Depth 12 }

function Get-PwPacketSource {
    param($Config, [switch]$ForSync)
    if ($WorkingTree) { return '' }
    if ($Ref) { return $Ref }
    if ($ForSync) { return '' }
    $main = "origin/$($Config.defaultBranch)"
    & git rev-parse --verify -q "$main^{commit}" *> $null
    if ($LASTEXITCODE -eq 0) { return $main }
    ''
}

function Get-PwSortKey {
    param($Packet)
    $prio = if ($Packet.Priority -match '^P(\d)$') { [int]$Matches[1] } else { 9 }
    $wave = if ($Packet.Wave -match '(\d+)') { [int]$Matches[1] } else { 99 }
    $num = if ($Packet.Id -match '-(\d+)$') { [int]$Matches[1] } else { 0 }
    '{0}-{1:D3}-{2:D5}' -f $prio, $wave, $num
}

function Get-PwBoardState {
    <# Packets, items by id and the packet lookup, read once. #>
    param($Config)
    $src = Get-PwPacketSource $Config
    $packets = @(Get-PwPackets -Config $Config -Phase $Phase -Ref $src)
    $items = @(Get-ProvItems)
    $byId = @{}
    foreach ($it in $items) {
        if ($byId.ContainsKey($it.Id)) { Write-Warning "$($it.Id) appears twice on the board ($($byId[$it.Id].Ref) and $($it.Ref)); using the first" ; continue }
        $byId[$it.Id] = $it
    }
    foreach ($bad in @($packets | Where-Object { -not $_.Id })) { Write-Warning "$($bad.Path) has no packet ID; skipped (validate-packets.ps1 says why)" }
    $packets = @($packets | Where-Object { $_.Id })
    $pkById = @{}; foreach ($p in $packets) { $pkById[$p.Id] = $p }
    @{ Packets = $packets; Items = $items; ItemsById = $byId; PacketsById = $pkById; Source = $(if ($src) { $src } else { 'working tree' }) }
}

function Add-PwRemoteItems {
    <# Puts the other repositories' packets that these packets depend on (remotes) into the state's ItemsById,
       for the verdicts. Such an ID is always read from its own repository, even if an item here carries it. #>
    param($Config, $State, $Packets)
    $remote = Get-PwRemoteItems -Config $Config -Ids @($Packets | ForEach-Object { $_.DependsOn })
    foreach ($id in $remote.Keys) { $State.ItemsById[$id] = $remote[$id] }
}

function Get-PwOpenPrFinder {
    param($Config)
    $cache = @{}
    {
        param($id)
        if (-not $cache.ContainsKey($id)) { $cache[$id] = Get-PwGhPrForPacket -Config $Config -PacketId $id -State open }
        $cache[$id]
    }.GetNewClosure()
}

function Resolve-PwItem {
    param($Config, [string]$Id)
    if (-not $Id) { Stop-Pw 'name a packet ID, such as PKT-12' }
    if ($Id -match '^#?(?<n>\d+)$' -or $Id -match '^AB#(?<n>\d+)$') {
        $hit = @(Get-ProvItems) | Where-Object { $_.Number -eq [int]$Matches.n } | Select-Object -First 1
    }
    else { $hit = @(Get-ProvItems) | Where-Object { $_.Id -eq $Id.ToUpperInvariant() } | Select-Object -First 1 }
    if (-not $hit) { Stop-Pw "$Id is not on the board (board.ps1 sync creates it from its packet file)" }
    $hit
}

function Get-PwItemRefLabel {
    param($Item)
    if (-not $Item) { return '' }
    if (Test-PwRemoteItem $Item) { return $(if ($Item.Number) { "$($Item.Repo)#$($Item.Number)" } else { $Item.Repo }) }
    if ((Get-ProvName) -eq 'azure-boards') { "AB#$($Item.Number)" } else { "#$($Item.Number)" }
}

function Format-PwItemBody {
    <# The item body for a packet: the file below its heading, dependency IDs annotated with their
       board refs, and a source marker carrying the file's and the body's hashes. #>
    param($Config, $Packet, [string]$FileText, [hashtable]$ItemsById)
    $body = $Packet.Body
    # Another repository's packet (remotes) keeps its bare ID: an item here with that ID isn't it.
    $deps = @($Packet.DependsOn | ForEach-Object { $it = if (Get-PwRemoteRepo -Config $Config -Id $_) { $null } else { $ItemsById[$_] }; if ($it) { "$_ ($(Get-PwItemRefLabel $it))" } else { $_ } })
    if ($deps.Count) {
        $body = [regex]::Replace($body, '(?m)^(?<pre>\s*[-*]\s+\*\*Depends on:\*\*\s*)(?<v>[^\r\n]*)$', { param($m) $m.Groups['pre'].Value + ($deps -join ', ') }, 'None', [TimeSpan]::FromSeconds(2))
    }
    $fileSha = (Get-PwSha256 $FileText).Substring(0, 16)
    $bodySha = (Get-PwSha256 $body).Substring(0, 16)
    $link = "https://github.com/$($Config.repo)/blob/$($Config.defaultBranch)/$($Packet.Path)"
    @"
$body

---
``packet:source path=$($Packet.Path) file=$fileSha body=$bodySha`` Generated from [$($Packet.Path)]($link). Edit the file and run board sync; edits made here are overwritten.
"@
}

function Split-PwItemBody {
    <# The part of an item body above its source marker, and the marker. #>
    param([string]$Body)
    $idx = $Body.IndexOf('`packet:source ')
    if ($idx -lt 0) { $idx = $Body.IndexOf('<code>packet:source ') }
    if ($idx -lt 0) { return @{ Content = $Body; Marker = $null } }
    $content = $Body.Substring(0, $idx).TrimEnd()
    if ($content.EndsWith('---')) { $content = $content.Substring(0, $content.Length - 3).TrimEnd() }
    @{ Content = $content; Marker = (Get-PwMarker $Body.Substring($idx)) }
}

function Get-PwTopoOrder {
    param($Packets)
    $byId = @{}; foreach ($p in $Packets) { $byId[$p.Id] = $p }
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $order = [System.Collections.Generic.List[object]]::new()
    $visit = $null
    $visit = {
        param($p)
        if (-not $seen.Add($p.Id)) { return }
        foreach ($d in $p.DependsOn) { if ($byId.ContainsKey($d)) { & $visit $byId[$d] } }
        $order.Add($p)
    }
    foreach ($p in ($Packets | Sort-Object { Get-PwSortKey $_ })) { & $visit $p }
    , $order
}

function Invoke-PwSync {
    param($Config)
    $src = Get-PwPacketSource $Config -ForSync
    $packets = @(Get-PwPackets -Config $Config -Phase $Phase -Ref $src)
    if ($packets.Count -eq 0) { Stop-Pw "no packet files under $($Config.paths.plans)/<phase>/packets/ $(if ($src) { "at $src" })" }
    $bad = $false
    foreach ($p in $packets) {
        foreach ($problem in (Test-PwPacket -Packet $p -Config $Config)) { Write-Output "PROBLEM $($p.Path): $problem"; $bad = $true }
    }
    $packets = @($packets | Where-Object { $_.Id })
    if (Get-PwCycles $packets) { Write-Output "PROBLEM dependency cycle: $((Get-PwCycles $packets) -join '; ')"; $bad = $true }
    $phases = [ordered]@{}
    foreach ($slug in @($packets | ForEach-Object Phase | Select-Object -Unique | Sort-Object)) {
        $ph = Get-PwPhaseInfo -Config $Config -Phase $slug -Ref $src
        $phases[$slug] = $ph
        if (@($ph.Roots).Count -gt 1) { Write-Output "PROBLEM $($ph.Path): more than one root item ($((@($ph.Roots) | ForEach-Object { "$($_.Line) $($_.Ref)" }) -join ', ')); keep one **Epic:**, **Feature:** or **User Story:** line"; $bad = $true }
    }
    if ($bad) { Write-Output 'Nothing synced: fix the packets (validate-packets.ps1 has the full check) and run sync again.'; exit 1 }

    $itemsById = @{}
    foreach ($it in @(Get-ProvItems)) { if (-not $itemsById.ContainsKey($it.Id)) { $itemsById[$it.Id] = $it } }
    $ordered = Get-PwTopoOrder $packets
    # The items this sync creates: in a dry run they don't exist yet, so placement calls them "(new)", and
    # any other missing item is not on the board.
    $creating = @($ordered | Where-Object { -not $itemsById.ContainsKey($_.Id) } | ForEach-Object Id)
    # Each phase's tree under the root item its plan names (the provider decides the levels). Worked out
    # first: a root that doesn't fit stops sync before anything is written.
    $trees = [ordered]@{}
    foreach ($slug in $phases.Keys) { $trees[$slug] = Resolve-ProvHierarchy -Phase $phases[$slug] -Packets @($ordered | Where-Object { $_.Phase -eq $slug }) }
    # Bodies come back as written on GitHub and (as Markdown) on Azure Boards, so an edit made on the board
    # shows as a hash mismatch and is kept from being overwritten. HTML descriptions don't round-trip.
    $roundTrips = -not ((Get-ProvName) -eq 'azure-boards' -and -not $Config.board.azureBoards.markdown)
    $counts = @{ created = 0; updated = 0; unchanged = 0; skipped = 0 }
    foreach ($p in $ordered) {
        $ph = $phases[$p.Phase]
        $fileText = if ($src) { (Invoke-PwGit show "${src}:$($p.Path)") -join "`n" } else { Get-Content -Raw -LiteralPath (Join-Path $Config.repoRoot $p.Path) }
        $title = "$($p.Id) · $($p.Title)"
        $body = Format-PwItemBody -Config $Config -Packet $p -FileText $fileText -ItemsById $itemsById
        $item = $itemsById[$p.Id]
        if (-not $item) {
            if ($DryRun) { Write-Output "would create $($p.Id) · $($p.Title) [$($p.InitialStatus)]"; $counts.created++; continue }
            $item = New-ProvItem -Packet $p -Title $title -Body $body -PhaseSlug $ph.Slug -PhaseTitle $ph.Title
            $itemsById[$p.Id] = $item
            Write-Output "created $($p.Id) $(Get-PwItemRefLabel $item) $($item.Url)"
            $counts.created++
            continue
        }
        $split = Split-PwItemBody $item.Body
        $newSplit = Split-PwItemBody $body
        # The phase is the GitHub milestone (the plan's heading) or Azure Boards' phase: tag (its folder name).
        # Comparing it moves items after the heading changes, so a phase never splits across two milestones.
        $phaseValue = if ((Get-ProvName) -eq 'azure-boards') { $ph.Slug } else { $ph.Title }
        $same = $split.Marker -and $split.Marker.Pairs['file'] -eq $newSplit.Marker.Pairs['file'] -and $split.Marker.Pairs['body'] -eq $newSplit.Marker.Pairs['body'] -and $item.Title -eq $title -and $item.Milestone -eq $phaseValue -and (Test-ProvItemComplete $item)
        if ($same) { $counts.unchanged++; continue }
        if ($roundTrips -and $split.Marker -and -not $Force) {
            $boardSha = (Get-PwSha256 $split.Content).Substring(0, 16)
            if ($boardSha -ne $split.Marker.Pairs['body']) {
                Write-Output "skipped $($p.Id) $(Get-PwItemRefLabel $item): its body was edited on the board since the last sync. Move those edits into $($p.Path), then sync -DryRun -Force, and sync -Force once the owner has seen what it changes."
                $counts.skipped++; continue
            }
        }
        if (-not $split.Marker -and -not $Force) {
            Write-Output "skipped $($p.Id) $(Get-PwItemRefLabel $item): the item wasn't created by sync (no source marker). Check it matches $($p.Path), then sync -DryRun -Force, and sync -Force once the owner has seen what it changes."
            $counts.skipped++; continue
        }
        if ($DryRun) { Write-Output "would update $($p.Id) $(Get-PwItemRefLabel $item)"; $counts.updated++; continue }
        Update-ProvItem -Item $item -Packet $p -Title $title -Body $body -PhaseSlug $ph.Slug -PhaseTitle $ph.Title
        Write-Output "updated $($p.Id) $(Get-PwItemRefLabel $item)"
        $counts.updated++
    }
    if (-not $DryRun) {
        foreach ($p in $packets) {
            $item = $itemsById[$p.Id]
            if (-not $item) { continue }
            $deps = @($p.DependsOn | Where-Object { -not (Get-PwRemoteRepo -Config $Config -Id $_) } | ForEach-Object { $itemsById[$_] } | Where-Object { $_ })
            $n = Set-ProvDependencies -Item $item -DependencyItems $deps
            if ($n) { Write-Output "linked $($p.Id) to $n dependenc$(if ($n -eq 1) { 'y' } else { 'ies' })" }
        }
    }
    foreach ($tree in $trees.Values) { Set-ProvHierarchy -Tree $tree -ItemsById $itemsById -Creating $creating -DryRun:$DryRun -Force:$Force | ForEach-Object { Write-Output $_ } }
    $known = [System.Collections.Generic.HashSet[string]]::new([string[]]@($packets | ForEach-Object Id))
    $phaseFilter = if ($Phase) { $Phase } else { $null }
    foreach ($it in $itemsById.Values) {
        if (-not $known.Contains($it.Id) -and -not $phaseFilter) { Write-Output "orphan $($it.Id) $(Get-PwItemRefLabel $it): on the board but no packet file" }
    }
    Write-Output ("sync: {0} created, {1} updated, {2} unchanged, {3} skipped{4}" -f $counts.created, $counts.updated, $counts.unchanged, $counts.skipped, $(if ($DryRun) { ' (dry run)' } else { '' }))
    if ($counts.skipped) { exit 1 }
}

function Format-PwRow {
    param($Packet, $Item, [string]$Extra = '')
    $ref = if ($Item) { Get-PwItemRefLabel $Item } else { '-' }
    $status = if ($Item) { $Item.Status } else { 'NOT ON BOARD' }
    $kind = if ($Packet.Kind -eq 'human') { 'human' } else { $Packet.Size }
    '{0,-8} {1,-7} {2,-15} {3,-3} {4,-5} {5,-4} {6}{7}' -f $Packet.Id, $ref, $status, $Packet.Priority, $kind, $Packet.Wave, $Packet.Title, $(if ($Extra) { "  [$Extra]" } else { '' })
}

if ($Command -in 'help', '-h', '--help', '-?' -or -not $Command) {
    $help = [regex]::Match((Get-Content -Raw -LiteralPath $PSCommandPath), '(?s)<#(.*?)#>').Groups[1].Value
    Write-Output (($help -split "`n" | ForEach-Object { $_ -replace '^\s*\.(SYNOPSIS|DESCRIPTION)\s*$', '' }) -join "`n").Trim()
    exit 0
}

try {
    $cfg = Get-PwSharedConfig -Path $ConfigPath
    # Pull requests always live on GitHub, so the GitHub helpers load first; the provider's own
    # *-Prov* functions then replace the GitHub ones where the board lives elsewhere.
    . "$PSScriptRoot/providers/github-common.ps1"
    . "$PSScriptRoot/providers/$($cfg.board.provider).ps1"
    Initialize-Prov -Config $cfg
    $lease = [int]$cfg.claims.leaseMinutes

    switch ($Command) {
        'setup' { Initialize-ProvBoard -DryRun:$DryRun | ForEach-Object { Write-Output $_ } }
        'sync' { Invoke-PwSync $cfg }
        'show' {
            $st = Get-PwBoardState $cfg
            $rows = foreach ($p in ($st.Packets | Sort-Object { Get-PwSortKey $_ })) {
                $it = $st.ItemsById[$p.Id]
                [pscustomobject]@{ Id = $p.Id; Ref = if ($it) { Get-PwItemRefLabel $it } else { $null }; Status = if ($it) { $it.Status } else { $null }; Priority = $p.Priority; Size = $p.Size; Wave = $p.Wave; Kind = $p.Kind; Title = $p.Title; DependsOn = $p.DependsOn; Url = if ($it) { $it.Url } else { $null } }
            }
            if ($Json) { Write-PwJson @($rows) }
            else {
                Write-Output "packets from $($st.Source); board: $(Get-ProvName)"
                foreach ($p in ($st.Packets | Sort-Object { Get-PwSortKey $_ })) { Format-PwRow $p $st.ItemsById[$p.Id] }
            }
        }
        'next' {
            $st = Get-PwBoardState $cfg
            $finder = Get-PwOpenPrFinder $cfg
            $ready = @($st.Packets | Where-Object { $_.Kind -eq 'packet' -and $st.ItemsById[$_.Id] -and $st.ItemsById[$_.Id].Status -eq 'Ready' } | Sort-Object { Get-PwSortKey $_ })
            Add-PwRemoteItems $cfg $st $ready
            $rows = foreach ($p in $ready) {
                $it = $st.ItemsById[$p.Id]
                $v = Get-PwVerdict -Packet $p -ItemsById $st.ItemsById -Config $cfg -FindOpenPr $finder
                [pscustomobject]@{ Id = $p.Id; Ref = Get-PwItemRefLabel $it; Verdict = $v.Verdict; Reasons = $v.Reasons; StackOn = $v.StackOn; StackPr = if ($v.StackPr) { $v.StackPr.number } else { $null }; Priority = $p.Priority; Wave = $p.Wave; Title = $p.Title }
            }
            $rows = @($rows)
            if ($Json) { Write-PwJson $rows }
            elseif (-not $rows.Count) { Write-Output 'no Ready packets' }
            else {
                foreach ($r in $rows) {
                    $why = if ($r.Verdict -eq 'STACK') { "on $($r.StackOn), PR #$($r.StackPr)" } elseif ($r.Reasons) { $r.Reasons -join '; ' } else { '' }
                    '{0,-7} {1,-8} {2,-7} {3,-3} {4,-4} {5}{6}' -f $r.Verdict, $r.Id, $r.Ref, $r.Priority, $r.Wave, $r.Title, $(if ($why) { "  ($why)" } else { '' })
                }
            }
        }
        'deps' {
            $st = Get-PwBoardState $cfg
            $id = ([string]$Rest[0]).ToUpperInvariant()
            $p = $st.PacketsById[$id]
            if (-not $p) { Stop-Pw "no packet file for $id (packets from $($st.Source))" }
            Add-PwRemoteItems $cfg $st @($p)
            $it = $st.ItemsById[$id]
            $v = Get-PwVerdict -Packet $p -ItemsById $st.ItemsById -Config $cfg -FindOpenPr (Get-PwOpenPrFinder $cfg)
            $status = if ($it) { $it.Status } else { 'NOT ON BOARD' }
            if ($Json) { Write-PwJson ([pscustomobject]@{ Id = $id; Status = $status; Verdict = $v.Verdict; Reasons = $v.Reasons; StackOn = $v.StackOn; StackPr = $v.StackPr }) }
            else {
                Write-Output "$($v.Verdict) $id ($status)"
                foreach ($d in $p.DependsOn) { $di = $st.ItemsById[$d]; Write-Output ("  {0,-8} {1}" -f $d, $(if ($di) { "$($di.Status) $(Get-PwItemRefLabel $di)" } else { 'NOT ON BOARD' })) }
                foreach ($r in $v.Reasons) { Write-Output "  - $r" }
                if ($v.StackOn) { Write-Output "  stack on $($v.StackOn): PR #$($v.StackPr.number), branch $($v.StackPr.headRefName)" }
            }
            if ($v.Verdict -eq 'BLOCKED' -or ($it -and $it.Status -ne 'Ready' -and $it.Status -ne 'In progress')) { exit 1 }
        }
        'get' { Write-PwJson (Resolve-PwItem $cfg $Rest[0]) }
        'set' {
            $item = Resolve-PwItem $cfg $Rest[0]
            $pairs = @($Rest | Select-Object -Skip 1)
            if (-not $pairs) { Stop-Pw 'usage: board.ps1 set <ID> Field=Value [Field=Value ...]' }
            $fields = [ordered]@{}
            foreach ($pair in $pairs) {
                $i = $pair.IndexOf('=')
                if ($i -lt 1) { Stop-Pw "expected Field=Value, got '$pair'" }
                $fields[$pair.Substring(0, $i).Trim()] = $pair.Substring($i + 1).Trim()
            }
            $h = @{}; foreach ($k in $fields.Keys) { $h[$k] = $fields[$k] }
            Set-ProvFields -Item $item -Fields $h
            foreach ($k in $fields.Keys) { Write-Output "$($item.Id) $(Get-PwItemRefLabel $item) $k = $($fields[$k])" }
        }
        'new-claim-id' { New-PwClaimId }
        'claim' {
            $item = Resolve-PwItem $cfg $Rest[0]
            if (-not $Rest[1]) { Stop-Pw 'usage: board.ps1 claim <ID> <claim-id> (board.ps1 new-claim-id makes one)' }
            $r = Invoke-PwClaim -Ref $item.Ref -ClaimId $Rest[1] -LeaseMinutes $lease -Force:$Force
            $line = '{0} {1} {2} {3}' -f $r.Result, $r.ClaimId, $r.CreatedAt.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'), $r.CommentId
            if ($r.Result -ne 'HOLD') { Write-Output $line; exit 1 }
            $left = [Math]::Max(0, [Math]::Floor($r.Left.TotalMinutes))
            $deferred = if ($r.PSObject.Properties['Deferred']) { $r.Deferred } else { $null }
            $how = if ($deferred) { "kept, renewal deferred: a claim comment $deferred left behind still fills the window; ${left}m left" }
            elseif (-not $r.Renewed) { "kept, nothing posted; ${left}m of ${lease}m left, renews under $([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.#}', $lease * 2 / 3))m" }
            elseif ($r.Lapsed) { "renewed after the lease had lapsed; ${left}m left" }
            else { "renewed; ${left}m left" }
            Write-Output "$line ($how)"
        }
        'release' {
            $item = Resolve-PwItem $cfg $Rest[0]
            if (-not $Rest[1]) { Stop-Pw 'usage: board.ps1 release <ID> <claim-id>' }
            $n = Remove-PwClaim -Ref $item.Ref -ClaimId $Rest[1]
            Write-Output "released $n claim comment(s) of $($Rest[1]) on $($item.Id)"
        }
        'claims' {
            $item = Resolve-PwItem $cfg $Rest[0]
            $live = Get-PwLiveClaims -Ref $item.Ref -LeaseMinutes $lease
            foreach ($c in $live.Claims) {
                $age = [int]($live.Now - $c.CreatedAt).TotalMinutes
                Write-Output ('{0} {1} {2} ({3}m ago)' -f $c.ClaimId, $c.CreatedAt.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ'), $c.CommentId, $age)
            }
        }
        'comment' {
            $item = Resolve-PwItem $cfg $Rest[0]
            $file = $Rest[1]
            if (-not $file -or -not (Test-Path -LiteralPath $file)) { Stop-Pw 'usage: board.ps1 comment <ID> <file>' }
            $c = Add-ProvComment -Ref $item.Ref -Body (Get-Content -Raw -LiteralPath $file)
            Write-Output "commented on $($item.Id) $(Get-PwItemRefLabel $item): $($c.Id)$(if ($c.Url) { " $($c.Url)" })"
        }
        'marker' {
            $item = Resolve-PwItem $cfg $Rest[0]
            $kind = $Rest[1]
            if (-not $kind) { Stop-Pw 'usage: board.ps1 marker <ID> <kind>' }
            $hit = Get-PwTrustedComments -Ref $item.Ref | Where-Object { $mk = Get-PwMarker $_.Body; $mk -and $mk.Kind -eq $kind } | Select-Object -Last 1
            if (-not $hit) { if ($Json) { 'null' }; exit 1 }
            $mk = Get-PwMarker $hit.Body
            if ($Json) { Write-PwJson ([pscustomobject]@{ Kind = $mk.Kind; Words = $mk.Words; Pairs = $mk.Pairs; CommentId = $hit.Id; CreatedAt = $hit.CreatedAt.UtcDateTime.ToString('o'); Body = $hit.Body }) }
            else { Write-Output $hit.Body }
        }
        'comments' {
            # The item's comments from trusted authors only: where the owner's answers are read.
            $item = Resolve-PwItem $cfg $Rest[0]
            $rows = @(Get-PwTrustedComments -Ref $item.Ref | ForEach-Object { [pscustomobject]@{ Id = $_.Id; CreatedAt = $_.CreatedAt.UtcDateTime.ToString('o'); Author = $_.Author; Body = $_.Body } })
            if ($Json) { Write-PwJson $rows }
            else { foreach ($c in $rows) { Write-Output "--- $($c.Author) $($c.CreatedAt)"; Write-Output $c.Body } }
        }
        'assign' { $item = Resolve-PwItem $cfg $Rest[0]; [void](Set-ProvAssignee -Ref $item.Ref); Write-Output "assigned $($item.Id)" }
        'ref' { Get-ProvRefText -Item (Resolve-PwItem $cfg $Rest[0]) }
        'pr' {
            $id = ([string]$Rest[0]).ToUpperInvariant()
            $pr = Get-PwGhPrForPacket -Config $cfg -PacketId $id -State open
            if (-not $pr) { $pr = Get-PwGhPrForPacket -Config $cfg -PacketId $id -State all }
            if (-not $pr) { if ($Json) { 'null' } else { Write-Output "no pull request for $id" }; exit 1 }
            if ($Json) { Write-PwJson $pr } else { Write-Output "#$($pr.number) $($pr.state) $($pr.headRefName) -> $($pr.baseRefName) $($pr.url)" }
        }
        'rounds' {
            $pr = ([string]$Rest[0]).TrimStart('#')
            if ($pr -notmatch '^\d+$') { Stop-Pw 'usage: board.ps1 rounds <PR number>' }
            # Round reports and the owner's settle checks, from trusted authors only (github-common.ps1).
            $rows = Get-PwGhRounds -Config $cfg -Pr $pr
            if ($Json) { Write-PwJson $rows }
            else { foreach ($r in $rows) { '{0} {1} head={2} tier={3} outcome={4} lenses={5}{6} confirmed={7} by {8}{9}' -f $r.Kind, $r.Round, $r.Head, $r.Tier, $r.Outcome, $r.Lenses, $(if ($r.Runs) { " runs=$($r.Runs)" } else { '' }), $r.Confirmed, $r.Author, $(if ($r.Consumed) { ' (used)' } else { '' }) } }
        }
        'locks' {
            $st = Get-PwBoardState $cfg
            $id = ([string]$Rest[0]).ToUpperInvariant()
            $p = $st.PacketsById[$id]
            if (-not $p) { Stop-Pw "no packet file for $id" }
            if (-not $p.Locks.Count) { Write-Output "$id holds no locks"; exit 0 }
            $globs = @(foreach ($l in $p.Locks) { (@($cfg.locks) | Where-Object { $_.name -eq $l }).paths })
            $prs = @(Invoke-PwGhJson pr list --repo $cfg.repo --state open --limit 1000 --json 'number,headRefName,files,url')
            if ($prs.Count -ge 1000) { Stop-Pw 'more than 1000 open pull requests; the lock check would be incomplete' }
            $own = "pkt/$($id.ToLowerInvariant())-"
            $taken = @(foreach ($pr in $prs) {
                    if ($pr.headRefName.StartsWith($own)) { continue }
                    # gh lists at most 100 files per PR; read the rest over REST before calling a lock free.
                    $paths = @($pr.files | ForEach-Object { $_.path })
                    if ($paths.Count -ge 100) { $paths = @(Invoke-PwGhPages "repos/$($cfg.repo)/pulls/$($pr.number)/files?per_page=100" | ForEach-Object { $_.filename; if ($_.ContainsKey('previous_filename') -and $_.previous_filename) { $_.previous_filename } }) }
                    if ($paths | Where-Object { Test-PwGlob $_ $globs }) { $pr }
                })
            if (-not $taken.Count) { Write-Output "locks free for ${id}: $($p.Locks -join ', ')"; exit 0 }
            foreach ($t in $taken) { Write-Output "TAKEN by PR #$($t.number) ($($t.headRefName)) $($t.url)" }
            exit 1
        }
        'reconcile' {
            $items = @(Get-ProvItems)
            $src = Get-PwPacketSource $cfg
            $known = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-PwPackets -Config $cfg -Ref $src | ForEach-Object Id))
            foreach ($it in $items) {
                if ($it.Closed -and $it.ClosedReason -ne 'not_planned' -and $it.Status -ne 'Done') {
                    if ($DryRun) { Write-Output "would set $($it.Id) Done (closed)" }
                    else { Set-ProvFields -Item $it -Fields @{ Status = 'Done' }; Write-Output "$($it.Id) $(Get-PwItemRefLabel $it) Status = Done (closed)" }
                }
                elseif (-not $it.Closed -and $it.Status -eq 'Done') { Write-Output "note: $($it.Id) $(Get-PwItemRefLabel $it) is Done but still open" }
                if (-not $known.Contains($it.Id)) { Write-Output "orphan $($it.Id) $(Get-PwItemRefLabel $it): no packet file" }
            }
        }
        default {
            $help = [regex]::Match((Get-Content -Raw -LiteralPath $PSCommandPath), '(?s)<#(.*?)#>').Groups[1].Value
            Write-Output (($help -split "`n" | ForEach-Object { $_ -replace '^\s*\.(SYNOPSIS|DESCRIPTION)\s*$', '' }) -join "`n").Trim()
            if ($Command -and $Command -notin 'help', '-h', '--help', '-?') { [Console]::Error.WriteLine("board: unknown command '$Command'"); exit 2 }
        }
    }
}
catch [PwError] {
    [Console]::Error.WriteLine("board: $($_.Exception.Message)")
    exit 2
}
catch {
    [Console]::Error.WriteLine("board: $($_.Exception.Message)")
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    exit 2
}
