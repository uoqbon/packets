#!/usr/bin/env pwsh
#Requires -Version 7.2
<#
.SYNOPSIS
  packet-dispatcher-guard.ps1: a preToolUse hook that refuses to start packet-dispatcher as a subagent.

.DESCRIPTION
  Only a person starts a dispatch. Some hosts offer the dispatcher to other agents despite its
  disable-model-invocation key, and the dispatcher's own check can't tell an agent's one-word task from a
  person's message, because a subagent gets its task as an ordinary user turn. This hook is the host-side
  rule: the installer puts it in .github/hooks/, and the agent runtime runs it before each subagent start.

  The host sends the call as JSON on stdin: Copilot's runtime as toolName and toolArgs (the subagent tool
  is task), the VS Code-compatible and Local formats as tool_name and tool_input. A call whose arguments
  name the packet-dispatcher agent is refused: the decision goes to stdout in both hosts' forms, the
  reason to stderr, and the exit code is 2, which both hosts treat as a deny. Every other call goes through
  untouched, and so does anything the hook can't read (exit 0): a broken hook must never block the
  dispatcher's own subagents, and the dispatcher's own check still stands behind it. Copilot's runtime
  treats any other failure of a preToolUse command as a deny, so the commands in packet-workflow.json
  start this script only when pwsh and the script are there, pass on its exit 2, and exit 0 for anything
  else (an older pwsh, an execution policy, a crash).
#>

$ErrorActionPreference = 'Stop'
try {
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw.Trim()) { exit 0 }
    $call = $raw | ConvertFrom-Json -AsHashtable
    if ($call -isnot [System.Collections.IDictionary]) { exit 0 }
    $toolArgs = $null
    foreach ($k in 'toolArgs', 'tool_input') { if ($call.Contains($k) -and $null -ne $call[$k]) { $toolArgs = $call[$k]; break } }
    # Copilot's runtime may pass the arguments as a JSON string.
    if ($toolArgs -is [string]) { $toolArgs = $toolArgs | ConvertFrom-Json -AsHashtable }
    if ($toolArgs -isnot [System.Collections.IDictionary]) { exit 0 }
    # The argument that names the agent to start, as the subagent tools spell it.
    $named = foreach ($k in 'agent_type', 'agentType', 'subagent_type', 'subagentType', 'agent_name', 'agentName', 'agent') {
        if ($toolArgs.Contains($k) -and $toolArgs[$k] -is [string]) { $toolArgs[$k] }
    }
    $isDispatcher = @($named | Where-Object { ($_.Trim() -replace '\.agent\.md$', '') -match '(^|[/:\\])packet-dispatcher$' }).Count -gt 0
    if (-not $isDispatcher) { exit 0 }
    $reason = 'packet-dispatcher is started only by a person (from the agents dropdown, or by typing /packet-dispatch), never by another agent. Tell the person to start it themselves.'
    $decision = [ordered]@{
        permissionDecision       = 'deny'
        permissionDecisionReason = $reason
        hookSpecificOutput       = [ordered]@{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $reason }
    }
    [Console]::Out.WriteLine(($decision | ConvertTo-Json -Compress -Depth 3))
    [Console]::Error.WriteLine($reason)
    exit 2
}
catch { exit 0 }
