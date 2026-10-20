# github-issues.ps1: the board as labelled GitHub issues, for repositories without a GitHub Project.
# Status, priority, size and wave are labels with a fixed prefix (status:in-review, priority:P0, …);
# an issue carries at most one label per prefix. The phase is the issue's milestone.

. "$PSScriptRoot/github-common.ps1"

function Initialize-Prov {
    param([Parameter(Mandatory)]$Config)
    $script:PwConfig = $Config
}

function Get-ProvName { 'github-issues' }

function Get-PwIssuesStatusLabel {
    param([Parameter(Mandatory)][string]$Status)
    "$($script:PwConfig.board.githubIssues.statusPrefix)$(Get-PwSlug $Status 6)"
}

function Get-PwIssuesValue {
    <# The value after a prefix among the labels, or $null. More than one is reported, the first wins. #>
    param([string[]]$Labels, [string]$Prefix, [string]$Ref)
    $hits = @($Labels | Where-Object { $_.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) })
    if ($hits.Count -gt 1) { Write-Warning "#${Ref} has several '$Prefix' labels ($($hits -join ', ')); using $($hits[0])" }
    if ($hits.Count -eq 0) { return $null }
    $hits[0].Substring($Prefix.Length).Trim()
}

function Get-ProvItems {
    $cfg = $script:PwConfig
    $gi = $cfg.board.githubIssues
    $bySlug = @{}; foreach ($s in $script:Statuses) { $bySlug[(Get-PwSlug $s 6)] = $s }
    @(foreach ($issue in (Get-PwGhIssues $cfg)) {
            $item = ConvertTo-PwGhItem -Issue $issue -Config $cfg
            if (-not $item.Id) { continue }
            $statusSlug = Get-PwIssuesValue $item.Labels $gi.statusPrefix $item.Ref
            $item.Status = if ($statusSlug -and $bySlug.ContainsKey($statusSlug.ToLowerInvariant())) { $bySlug[$statusSlug.ToLowerInvariant()] }
            elseif ($item.Closed) { 'Done' } else { 'Backlog' }
            $item.Priority = Get-PwIssuesValue $item.Labels $gi.priorityPrefix $item.Ref
            $item.Size = Get-PwIssuesValue $item.Labels $gi.sizePrefix $item.Ref
            $item.Wave = Get-PwIssuesValue $item.Labels $gi.wavePrefix $item.Ref
            $item
        })
}

function Set-ProvFields {
    <# Fields: Status, Priority, Size, Wave (labels). Target lives in the issue body. #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][hashtable]$Fields)
    $cfg = $script:PwConfig
    $gi = $cfg.board.githubIssues
    $add = [System.Collections.Generic.List[string]]::new()
    $remove = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Fields.Keys) {
        $value = [string]$Fields[$name]
        if ($name -eq 'Target') { Write-Warning 'github-issues keeps Target in the issue body; sync the packet file to change it'; continue }
        if (-not $value) { continue }
        if ($name -eq 'Status') {
            if ($script:Statuses -notcontains $value) { Stop-Pw "unknown status '$value' (one of: $($script:Statuses -join ', '))" }
            $prefix = $gi.statusPrefix; $label = Get-PwIssuesStatusLabel $value
        }
        elseif ($name -eq 'Priority') {
            if ($value -notmatch '^P[0-3]$') { Stop-Pw "Priority must be P0-P3 (got '$value')" }
            $prefix = $gi.priorityPrefix; $label = "$prefix$value"
        }
        elseif ($name -eq 'Size') { $prefix = $gi.sizePrefix; $label = "$prefix$value" }
        elseif ($name -eq 'Wave') { $prefix = $gi.wavePrefix; $label = "$prefix$value" }
        else { Stop-Pw "github-issues has no field '$name' (Status, Priority, Size, Wave)" }
        $add.Add($label)
        foreach ($l in $Item.Labels) { if ($l.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and $l -ne $label) { $remove.Add($l) } }
    }
    Set-PwGhLabels -Config $cfg -Number $Item.Number -Add $add -Remove $remove -Current $Item.Labels
}

function New-ProvItem {
    param([Parameter(Mandatory)]$Packet, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Body, [string]$PhaseSlug = '', [string]$PhaseTitle = '')
    $cfg = $script:PwConfig
    $gi = $cfg.board.githubIssues
    $labels = @($cfg.labels.packet)
    if ($Packet.Kind -eq 'human') { $labels += $cfg.labels.human }
    $labels += Get-PwIssuesStatusLabel $Packet.InitialStatus
    if ($Packet.Priority) { $labels += "$($gi.priorityPrefix)$($Packet.Priority)" }
    if ($Packet.Size) { $labels += "$($gi.sizePrefix)$($Packet.Size)" }
    if ($Packet.Wave) { $labels += "$($gi.wavePrefix)$($Packet.Wave)" }
    foreach ($l in $labels) { [void](Confirm-PwGhLabel -Config $cfg -Name $l) }
    $milestone = if ($PhaseTitle) { Confirm-PwGhMilestone -Config $cfg -Title $PhaseTitle } else { 0 }
    $issue = New-PwGhIssue -Config $cfg -Title $Title -Body $Body -Labels $labels -Milestone $milestone
    $item = ConvertTo-PwGhItem -Issue $issue -Config $cfg
    $item.Status = $Packet.InitialStatus
    $item
}

function Update-ProvItem {
    <# Rewrites title and body, and brings Priority, Size and Wave in line with the packet. Never Status. #>
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$Packet, [Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][string]$Body, [string]$PhaseSlug = '', [string]$PhaseTitle = '')
    $milestone = if ($PhaseTitle) { Confirm-PwGhMilestone -Config $script:PwConfig -Title $PhaseTitle } else { 0 }
    Update-PwGhIssue -Config $script:PwConfig -Number $Item.Number -Title $Title -Body $Body -Milestone $milestone
    $f = @{}
    if ($Packet.Priority -and $Packet.Priority -ne $Item.Priority) { $f.Priority = $Packet.Priority }
    if ($Packet.Size -and $Packet.Size -ne $Item.Size) { $f.Size = $Packet.Size }
    if ($Packet.Wave -and $Packet.Wave -ne $Item.Wave) { $f.Wave = $Packet.Wave }
    if ($f.Count) { Set-ProvFields -Item $Item -Fields $f }
}

function Initialize-ProvBoard {
    <# Creates the labels the board needs. Never edits or deletes an existing label. #>
    param([switch]$DryRun)
    $cfg = $script:PwConfig
    $gi = $cfg.board.githubIssues
    $created = [System.Collections.Generic.List[string]]::new()
    foreach ($l in (Initialize-PwGhLabels -Config $cfg -DryRun:$DryRun)) { $created.Add($l) }
    $colors = @{ 'Backlog' = 'cfd3d7'; 'Ready' = '0e8a16'; 'In progress' = 'fbca04'; 'In review' = '5319e7'; 'Ready to merge' = '1d76db'; 'Needs human' = 'd93f0b'; 'Done' = '000000' }
    foreach ($s in $script:Statuses) { if (Confirm-PwGhLabel -Config $cfg -Name (Get-PwIssuesStatusLabel $s) -Color $colors[$s] -Description "Packet status: $s" -DryRun:$DryRun) { $created.Add((Get-PwIssuesStatusLabel $s)) } }
    foreach ($p in 'P0', 'P1', 'P2', 'P3') { if (Confirm-PwGhLabel -Config $cfg -Name "$($gi.priorityPrefix)$p" -Color 'b60205' -DryRun:$DryRun) { $created.Add("$($gi.priorityPrefix)$p") } }
    foreach ($s in @($cfg.sizes.Keys)) { if (Confirm-PwGhLabel -Config $cfg -Name "$($gi.sizePrefix)$s" -Color 'c2e0c6' -DryRun:$DryRun) { $created.Add("$($gi.sizePrefix)$s") } }
    $verb = if ($DryRun) { 'would create' } else { 'created' }
    if ($created.Count) { "$verb labels: $($created -join ', ')" } else { 'labels: all present' }
}
