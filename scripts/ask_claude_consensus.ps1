param(
  [string]$Workspace = (Get-Location).Path,
  [Alias("t")]
  [string]$Task,
  [Alias("p")]
  [string]$Plan,
  [int]$Round = 1,
  [Alias("f")]
  [string[]]$File = @(),
  [string]$Session,
  [string]$Model,
  [string]$Effort = "max",
  [string]$PermissionMode = "plan",
  [Alias("o")]
  [string]$Output,
  [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Show-Usage {
  @"
Usage:
  ask_claude_consensus.ps1 -Task <text> -Plan <text> [options]

Required:
  -Task, -t <text>             Original user request or requirement
  -Plan, -p <text>             Current Codex plan for Claude to review

Consensus:
  -Round <n>                   Review round number (default: 1)
  -Session <id>                Resume the Claude session for this same requirement

File context (optional, repeatable):
  -File, -f <path>             Priority file path. Relative paths resolve from -Workspace

Options:
  -Workspace <path>            Workspace directory (default: current directory)
  -Model <name>                Claude model override
  -Effort <level>              Effort: low, medium, high, max (default: max)
  -PermissionMode <mode>       Claude permission mode for new sessions (default: plan)
  -Output, -o <path>           Output markdown path (default: .runtime/<timestamp>.md)
  -Help                        Show this help

Output (on success):
  session_id=<session_id>      Keep only inside this consensus subagent/request
  output_path=<file>           Path to Claude response markdown
"@
}

function Fail([string]$Message) {
  [Console]::Error.WriteLine("[ERROR] $Message")
  exit 1
}

function Require-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Fail "Missing required command: $Name"
  }
}

function Trim-Text([AllowNull()][string]$Value) {
  if ($null -eq $Value) { return "" }
  return $Value.Trim()
}

function Resolve-FileRef([string]$WorkspacePath, [string]$Raw) {
  $cleaned = (Trim-Text $Raw)
  if ([string]::IsNullOrWhiteSpace($cleaned)) { return "" }
  $cleaned = $cleaned -replace '#L\d+$', ''
  $cleaned = $cleaned -replace ':\d+(-\d+)?$', ''
  if (-not [System.IO.Path]::IsPathRooted($cleaned)) {
    $cleaned = Join-Path $WorkspacePath $cleaned
  }
  if (Test-Path -LiteralPath $cleaned) {
    return (Resolve-Path -LiteralPath $cleaned).Path
  }
  return $cleaned
}

if ($Help) {
  Show-Usage
  exit 0
}

if ([string]::IsNullOrWhiteSpace($Workspace)) {
  Fail "Workspace path is empty."
}
if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) {
  Fail "Workspace does not exist: $Workspace"
}
$Workspace = (Resolve-Path -LiteralPath $Workspace).Path

$Task = Trim-Text $Task
$Plan = Trim-Text $Plan
if ([string]::IsNullOrWhiteSpace($Task)) {
  Fail "Missing required -Task."
}
if ([string]::IsNullOrWhiteSpace($Plan)) {
  Fail "Missing required -Plan."
}
if ($Round -lt 1) {
  Fail "-Round must be a positive integer."
}

Require-Command "claude"
Require-Command "jq"

if ([string]::IsNullOrWhiteSpace($Output)) {
  $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
  $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
  $skillDir = Split-Path -Parent $scriptDir
  $Output = Join-Path $skillDir ".runtime/$timestamp.md"
}
$outputDir = Split-Path -Parent $Output
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
  New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
}

$fileLines = New-Object System.Collections.Generic.List[string]
foreach ($entry in $File) {
  foreach ($item in ($entry -split ",")) {
    $resolved = Resolve-FileRef $Workspace $item
    if ([string]::IsNullOrWhiteSpace($resolved)) { continue }
    $existsTag = "missing"
    if (Test-Path -LiteralPath $resolved) { $existsTag = "exists" }
    $fileLines.Add("- $resolved ($existsTag)")
  }
}

$prompt = @"
You are Claude reviewing a Codex implementation plan in read-only mode.

Review contract:
- The first non-empty line of your response must be exactly AGREE or ISSUES.
- Do not wrap AGREE or ISSUES in markdown, headings, punctuation, prefixes, or suffixes.
- Return AGREE if the plan is executable and covers the important risks.
- Return ISSUES if there are blocking problems, incorrect assumptions, missing context, or test gaps.
- If returning ISSUES, list only material issues that should change the plan.
- Do not edit files. Do not propose unrelated improvements.

Workspace:
$Workspace

Consensus round:
$Round

Original user request:
$Task

Current Codex plan:
$Plan
"@

if ($fileLines.Count -gt 0) {
  $prompt += "`nRelevant file hints:`n"
  $prompt += ($fileLines -join "`n")
}

$claudeArgs = @("-p", "--verbose", "--output-format", "stream-json", "--effort", $Effort)
if ([string]::IsNullOrWhiteSpace($Session)) {
  $claudeArgs += @("--permission-mode", $PermissionMode)
} else {
  $claudeArgs += @("--resume", $Session)
}
if (-not [string]::IsNullOrWhiteSpace($Model)) {
  $claudeArgs += @("--model", $Model)
}

$stderrFile = [System.IO.Path]::GetTempFileName()
$jsonFile = [System.IO.Path]::GetTempFileName()
$promptFile = [System.IO.Path]::GetTempFileName()

try {
  Set-Content -LiteralPath $promptFile -Value $prompt -NoNewline
  Push-Location $Workspace
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "claude"
    foreach ($arg in $claudeArgs) { [void]$psi.ArgumentList.Add($arg) }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::Start($psi)
    $process.StandardInput.Write($prompt)
    $process.StandardInput.Close()

    while (-not $process.StandardOutput.EndOfStream) {
      $line = $process.StandardOutput.ReadLine()
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $cleaned = $line.Replace("`r", "").Replace([char]4, "")
      if (-not $cleaned.StartsWith("{")) { continue }
      Add-Content -LiteralPath $jsonFile -Value $cleaned
      if ($cleaned -like '*"type":"system"*' -and $cleaned -like '*"session_id"*') {
        $sid = $cleaned | jq -r '.session_id // empty' 2>$null
        if (-not [string]::IsNullOrWhiteSpace($sid)) {
          [Console]::Error.WriteLine("[claude] session $sid")
        }
      }
    }

    $stderrText = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
      [Console]::Error.Write($stderrText)
    }
    if ($process.ExitCode -ne 0 -and -not ((Test-Path -LiteralPath $jsonFile) -and ((Get-Item -LiteralPath $jsonFile).Length -gt 0))) {
      Fail "Claude exited with code $($process.ExitCode)"
    }
  } finally {
    Pop-Location
  }

  $threadId = Get-Content -LiteralPath $jsonFile | jq -sr '[.[] | .session_id? // empty] | .[0] // empty' 2>$null

  Get-Content -LiteralPath $jsonFile | jq -sr '
    def assistant_chunks:
      .[]
      | select(.type == "assistant")
      | .message.content?
      | if type == "array" then .[]?
        elif type == "object" then .
        elif type == "string" and . != "" then {type: "text", text: .}
        else empty end
      | if .type == "text" and (.text // "") != "" then
          .text
        elif .type == "tool_use" and (.name // "") != "" then
          .name as $name
          | if ["Read", "Grep", "Glob", "LS"] | index($name) then
            empty
          else
            "### Tool: `" + $name + "`"
          end
        else empty end;

    def result_chunks:
      .[]
      | select(.type == "result" and (.result // "") != "")
      | .result;

    [assistant_chunks, result_chunks]
    | reduce .[] as $chunk ([]; if length > 0 and .[-1] == $chunk then . else . + [$chunk] end)
    | .[]
  ' 2>$null | Set-Content -LiteralPath $Output

  if (-not (Test-Path -LiteralPath $Output) -or (Get-Item -LiteralPath $Output).Length -eq 0) {
    Set-Content -LiteralPath $Output -Value "(no response from claude)"
  }

  if (-not [string]::IsNullOrWhiteSpace($threadId)) {
    "session_id=$threadId"
  }
  "output_path=$Output"
} finally {
  Remove-Item -LiteralPath $stderrFile, $jsonFile, $promptFile -Force -ErrorAction SilentlyContinue
}
