# local.ps1: a board kept in a JSON file inside the repository's git directory (<git-common-dir>/
# packet-board.json), so every worktree of one clone sees the same board and nothing is committed. It is
# for trying the workflow without a hosted board and for the kit's own tests: one machine only, no web
# view. Pull requests still live on GitHub.

$script:LocalPath = $null

function Initialize-Prov {
    param([Parameter(Mandatory)]$Config)
    $script:PwConfig = $Config
    $common = (Invoke-PwGit -C $Config.repoRoot rev-parse --git-common-dir | Select-Object -First 1).Trim()
    if (-not [System.IO.Path]::IsPathRooted($common)) { $common = Join-Path $Config.repoRoot $common }
    $script:LocalPath = Join-Path $common 'packet-board.json'
}

function Get-ProvName { 'local' }

function Use-PwLocalBoard {
    <# Runs Action on the board state under an exclusive file lock and saves it if Action returns $true. #>
    param([Parameter(Mandatory)][scriptblock]$Action)
    $lockPath = "$($script:LocalPath).lock"
    $lock = $null
    for ($i = 0; $i -lt 100 -and -not $lock; $i++) {
        try { $lock = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { Start-Sleep -Milliseconds 50 }
    }
    if (-not $lock) { Stop-Pw "could not lock $lockPath" }
    try {
        $state = if (Test-Path -LiteralPath $script:LocalPath) { Get-Content -Raw -LiteralPath $script:LocalPath | ConvertFrom-Json -AsHashtable -Depth 64 } else { $null }
        if (-not $state) { $state = @{ nextNumber = 1; nextCommentId = 1; items = @(); comments = @{} } }
        $state.items = [System.Collections.Generic.List[object]]@($state.items)
        $result = & $Action $state
        if ($result.Save) { [System.IO.File]::WriteAllText($script:LocalPath, ($state | ConvertTo-Json -Depth 64), [System.Text.UTF8Encoding]::new($false)) }
        $result.Value
    }
    finally { $lock.Dispose() }
}

function ConvertTo-PwLocalItem {
    param($Row)
    [pscustomobject]@{
        Id = $Row.id; Ref = [string]$Row.number; Number = [int]$Row.number; DbId = [long]$Row.number; NodeId = $null
        Url = "local:$($Row.number)"; Title = $Row.title; Body = $Row.body; Labels = @($Row.labels)
        Kind = $Row.kind; Closed = [bool]$Row.closed; ClosedReason = $Row.closedReason; UpdatedAt = $Row.updatedAt
        Milestone = $Row.milestone; Assignees = @($Row.assignees); Status = $Row.status; Priority = $Row.priority
        Size = $Row.size; Wave = $Row.wave; Target = $Row.target; ProjectItemId = $null; Dependencies = @($Row.dependencies); Parent = $Row.parent
    }
}

function Get-ProvItems {
    Use-PwLocalBoard { param($s) @{ Save = $false; Value = @($s.items | ForEach-Object { ConvertTo-PwLocalItem $_ }) } }
}

function Update-PwLocalRow {
    param([int]$Number, [scriptblock]$Change)
    Use-PwLocalBoard {
        param($s)
        $row = $s.items | Where-Object { [int]$_.number -eq $Number } | Select-Object -First 1
        if (-not $row) { Stop-Pw "local board has no item $Number" }
        & $Change $row
        $row.updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        @{ Save = $true; Value = (ConvertTo-PwLocalItem $row) }
    }
}

function Set-ProvFields {
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][hashtable]$Fields)
    foreach ($k in $Fields.Keys) {
        if ($k -notin 'Status', 'Priority', 'Size', 'Wave', 'Target', 'Closed') { Stop-Pw "local board has no field '$k' (Status, Priority, Size, Wave, Target, Closed)" }
        if ($k -eq 'Status' -and $script:Statuses -notcontains $Fields[$k]) { Stop-Pw "unknown status '$($Fields[$k])' (one of: $($script:Statuses -join ', '))" }
    }
    [void](Update-PwLocalRow -Number $Item.Number -Change {
            param($row)
            foreach ($k in $Fields.Keys) {
                if ($k -eq 'Closed') { $row.closed = [bool]::Parse([string]$Fields[$k]); $row.closedReason = if ($row.closed) { 'completed' } else { $null } }
                else { $row[$k.ToLowerInvariant()] = [string]$Fields[$k] }
            }
        })
}

function New-ProvItem {
    param([Parameter(Mandatory)]$Packet, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Body, [string]$PhaseSlug = '', [string]$PhaseTitle = '')
    $cfg = $script:PwConfig
    Use-PwLocalBoard {
        param($s)
        $n = [int]$s.nextNumber; $s.nextNumber = $n + 1
        $row = @{
            number = $n; id = $Packet.Id; title = $Title; body = $Body; kind = $Packet.Kind
            labels = @($cfg.labels.packet) + $(if ($Packet.Kind -eq 'human') { @($cfg.labels.human) } else { @() })
            status = $Packet.InitialStatus; priority = $Packet.Priority; size = $Packet.Size; wave = $Packet.Wave; target = $Packet.Target
            closed = $false; closedReason = $null; milestone = $PhaseTitle; assignees = @(); dependencies = @(); parent = $null
            updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $s.items.Add($row)
        @{ Save = $true; Value = (ConvertTo-PwLocalItem $row) }
    }
}

function Update-ProvItem {
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$Packet, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Body, [string]$PhaseSlug = '', [string]$PhaseTitle = '')
    [void](Update-PwLocalRow -Number $Item.Number -Change {
            param($row)
            $row.title = $Title; $row.body = $Body; $row.priority = $Packet.Priority; $row.size = $Packet.Size; $row.wave = $Packet.Wave; $row.target = $Packet.Target
            if ($PhaseTitle) { $row.milestone = $PhaseTitle }
        })
}

function Get-ProvComments {
    param([Parameter(Mandatory)][string]$Ref)
    Use-PwLocalBoard {
        param($s)
        $list = if ($s.comments.ContainsKey($Ref)) { @($s.comments[$Ref]) } else { @() }
        @{ Save = $false; Value = @($list | ForEach-Object { [pscustomobject]@{ Id = [long]$_.id; CreatedAt = [DateTimeOffset]$_.createdAt; Body = [string]$_.body; Author = 'local' } }) }
    }
}

function Add-ProvComment {
    param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)][string]$Body)
    Use-PwLocalBoard {
        param($s)
        $id = [long]$s.nextCommentId; $s.nextCommentId = $id + 1
        $c = @{ id = $id; createdAt = [DateTimeOffset]::UtcNow.ToString('o'); body = $Body }
        $list = [System.Collections.Generic.List[object]]::new()
        if ($s.comments.ContainsKey($Ref)) { foreach ($x in @($s.comments[$Ref])) { $list.Add($x) } }
        $list.Add($c); $s.comments[$Ref] = $list
        @{ Save = $true; Value = [pscustomobject]@{ Id = $id; CreatedAt = [DateTimeOffset]$c.createdAt; Body = $Body; Url = $null } }
    }
}

function Remove-ProvComment {
    param([Parameter(Mandatory)][string]$Ref, [Parameter(Mandatory)]$CommentId)
    [void](Use-PwLocalBoard {
        param($s)
        if ($s.comments.ContainsKey($Ref)) { $s.comments[$Ref] = @($s.comments[$Ref] | Where-Object { [string]$_.id -ne [string]$CommentId }) }
        @{ Save = $true; Value = $null }
    })
}

function Get-ProvCurrentUser { 'local' }

function Get-ProvRefText { param([Parameter(Mandatory)]$Item) "Packet $($Item.Id) (local board item $($Item.Number))" }
function Set-ProvAssignee { param([Parameter(Mandatory)][string]$Ref) }

function Resolve-ProvHierarchy {
    <# As on GitHub: every packet and human task of the phase sits under the plan's root item, a human task
       with a Parent line under that packet's item. #>
    param([Parameter(Mandatory)]$Phase, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Packets)
    [pscustomobject]@{ Phase = $Phase; Packets = @($Packets) }
}

function Set-ProvHierarchy {
    param([Parameter(Mandatory)]$Tree, [Parameter(Mandatory)][hashtable]$ItemsById, [switch]$DryRun, [switch]$Force)
    $root = $Tree.Phase.Root
    if (-not $root) { return }
    $ref = $root.Ref -replace '^(AB)?#', ''
    foreach ($p in $Tree.Packets) {
        $item = $ItemsById[$p.Id]
        $target = $ref; $label = "$($root.Level) #$ref"
        if ($p.Kind -eq 'human' -and $p.Parent) {
            $parentItem = $ItemsById[$p.Parent]
            if ($parentItem) { $target = [string]$parentItem.Number; $label = "$($p.Parent) #$target" }
            elseif ($DryRun) { $target = ''; $label = "$($p.Parent) (new)" }
            else { if ($item) { "note: $($p.Id) #$($item.Number) was left where it is: its Parent $($p.Parent) isn't on the board" }; continue }
        }
        if (-not $item) { if ($DryRun) { "would put $($p.Id) (new) under $label" }; continue }
        $from = [string]$item.Parent
        if ($target -and $from -eq $target) { continue }
        # As on GitHub and Azure Boards: an item under another parent is named, and -Force moves it.
        if ($from -and -not $Force) { "note: $($p.Id) #$($item.Number) is under #$from, and its place is under ${label}: sync -Phase $($Tree.Phase.Slug) -Force moves it, and also overwrites any body this sync skipped as edited on the board, so move those edits into the packet files first (with -DryRun, it shows every change)"; continue }
        if ($DryRun) { "would $(if ($from) { 'move' } else { 'put' }) $($p.Id) #$($item.Number) under $label$(if ($from) { " (now under #$from)" })"; continue }
        [void](Update-PwLocalRow -Number $item.Number -Change { param($row) $row.parent = $target })
        "$(if ($from) { 'moved' } else { 'linked' }) $($p.Id) under $label$(if ($from) { " (was under #$from)" })"
    }
}

function Set-ProvDependencies {
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$DependencyItems)
    $want = @($DependencyItems | ForEach-Object { [int]$_.Number })
    $new = @($want | Where-Object { @($Item.Dependencies) -notcontains $_ })
    if (-not $new.Count) { return 0 }
    [void](Update-PwLocalRow -Number $Item.Number -Change { param($row) $row.dependencies = @($want) })
    $new.Count
}

function Initialize-ProvBoard {
    param([switch]$DryRun)
    "local board: $script:LocalPath (shared by every worktree of this clone; never committed)"
}
