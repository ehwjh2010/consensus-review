#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ask_claude_consensus.sh --task <text> --plan <text> [options]

Required:
  -t, --task <text>            Original user request or requirement
  -p, --plan <text>            Current Codex plan for Claude to review

Consensus:
      --round <n>              Review round number (default: 1)
      --session <id>           Resume the Claude session for this same requirement

File context (optional, repeatable):
  -f, --file <path>            Priority file path. Relative paths resolve from --workspace

Options:
  -w, --workspace <path>       Workspace directory (default: current directory)
      --model <name>           Claude model override
      --effort <level>         Effort: low, medium, high, max (default: medium)
      --permission-mode <mode> Claude permission mode for new sessions (default: plan)
  -o, --output <path>          Output markdown path (default: .runtime/<timestamp>.md)
  -h, --help                   Show this help

Output (on success):
  session_id=<session_id>      Keep only inside this consensus subagent/request
  output_path=<file>           Path to Claude response markdown
USAGE
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing required command: $1"
  fi
}

take_value() {
  local option="$1"
  if [[ $# -lt 2 || -z "${2:-}" ]]; then
    fail "Missing value for $option."
  fi
  printf '%s' "$2"
}

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

to_abs_if_exists() {
  local target="$1"
  if [[ -e "$target" ]]; then
    local dir
    dir="$(cd "$(dirname "$target")" && pwd)"
    echo "$dir/$(basename "$target")"
    return
  fi
  echo "$target"
}

resolve_file_ref() {
  local workspace="$1" raw="$2" cleaned
  cleaned="$(trim_whitespace "$raw")"
  [[ -z "$cleaned" ]] && { echo ""; return; }
  if [[ "$cleaned" =~ ^(.+)#L[0-9]+$ ]]; then cleaned="${BASH_REMATCH[1]}"; fi
  if [[ "$cleaned" =~ ^(.+):[0-9]+(-[0-9]+)?$ ]]; then cleaned="${BASH_REMATCH[1]}"; fi
  if [[ "$cleaned" != /* ]]; then cleaned="$workspace/$cleaned"; fi
  to_abs_if_exists "$cleaned"
}

append_file_refs() {
  local raw="$1" item
  IFS=',' read -r -a items <<< "$raw"
  for item in "${items[@]}"; do
    local trimmed
    trimmed="$(trim_whitespace "$item")"
    [[ -n "$trimmed" ]] && file_refs+=("$trimmed")
  done
}

workspace="${PWD}"
task_text=""
plan_text=""
round="1"
model=""
effort="medium"
permission_mode="plan"
output_path=""
session_id=""
file_refs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace) workspace="$(take_value "$1" "${2:-}")"; shift 2 ;;
    -t|--task) task_text="$(take_value "$1" "${2:-}")"; shift 2 ;;
    -p|--plan) plan_text="$(take_value "$1" "${2:-}")"; shift 2 ;;
    --round) round="$(take_value "$1" "${2:-}")"; shift 2 ;;
    -f|--file|--focus) append_file_refs "$(take_value "$1" "${2:-}")"; shift 2 ;;
    --session) session_id="$(take_value "$1" "${2:-}")"; shift 2 ;;
    --model) model="$(take_value "$1" "${2:-}")"; shift 2 ;;
    --effort|--reasoning) effort="$(take_value "$1" "${2:-}")"; shift 2 ;;
    --permission-mode) permission_mode="$(take_value "$1" "${2:-}")"; shift 2 ;;
    -o|--output) output_path="$(take_value "$1" "${2:-}")"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) echo "[ERROR] Unexpected argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$workspace" ]] || fail "Workspace path is empty."
[[ -d "$workspace" ]] || fail "Workspace does not exist: $workspace"
workspace="$(cd "$workspace" && pwd)"

task_text="$(trim_whitespace "$task_text")"
plan_text="$(trim_whitespace "$plan_text")"
round="$(trim_whitespace "$round")"
[[ -n "$task_text" ]] || fail "Missing required --task."
[[ -n "$plan_text" ]] || fail "Missing required --plan."
[[ "$round" =~ ^[0-9]+$ ]] || fail "--round must be a positive integer."
(( round >= 1 )) || fail "--round must be a positive integer."

require_cmd claude
require_cmd jq

if [[ -z "$output_path" ]]; then
  timestamp="$(date -u +"%Y%m%d-%H%M%S")"
  skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  output_path="$skill_dir/.runtime/${timestamp}.md"
fi
mkdir -p "$(dirname "$output_path")"

file_block=""
if (( ${#file_refs[@]} > 0 )); then
  file_block=$'\nRelevant file hints:'
  for ref in "${file_refs[@]}"; do
    resolved="$(resolve_file_ref "$workspace" "$ref")"
    [[ -z "$resolved" ]] && continue
    exists_tag="missing"
    [[ -e "$resolved" ]] && exists_tag="exists"
    file_block+=$'\n- '"${resolved} (${exists_tag})"
  done
fi

prompt="$(cat <<PROMPT
You are Claude reviewing a Codex implementation plan in read-only mode.

Review contract:
- The first non-empty line of your response must be exactly AGREE or ISSUES.
- Do not wrap AGREE or ISSUES in markdown, headings, punctuation, prefixes, or suffixes.
- Return AGREE if the plan is executable and covers the important risks.
- Return ISSUES if there are blocking problems, incorrect assumptions, missing context, or test gaps.
- If returning ISSUES, list only material issues that should change the plan.
- Do not edit files. Do not propose unrelated improvements.

Workspace:
$workspace

Consensus round:
$round

Original user request:
$task_text

Current Codex plan:
$plan_text
PROMPT
)"

if [[ -n "$file_block" ]]; then
  prompt+=$'\n'"$file_block"
fi

cmd=(claude -p --verbose --output-format stream-json --effort "$effort")
if [[ -n "$session_id" ]]; then
  cmd+=(--resume "$session_id")
else
  cmd+=(--permission-mode "$permission_mode")
fi
[[ -n "$model" ]] && cmd+=(--model "$model")

stderr_file="$(mktemp)"
json_file="$(mktemp)"
prompt_file="$(mktemp)"
trap 'rm -f "$stderr_file" "$json_file" "$prompt_file"' EXIT

printf "%s" "$prompt" > "$prompt_file"

run_claude() {
  (cd "$workspace" && "${cmd[@]}" < "$prompt_file" 2>"$stderr_file")
}

print_progress() {
  local line="$1" text tool
  case "$line" in
    *'"type":"system"'*'"session_id"'*)
      text="$(printf '%s' "$line" | jq -r '.session_id // empty' 2>/dev/null | cut -c1-80)"
      [[ -n "$text" ]] && echo "[claude] session $text" >&2
      ;;
    *'"type":"assistant"'*)
      text="$(printf '%s' "$line" | jq -r '
        .message.content?
        | if type == "array" then .[]?
          elif type == "object" then .
          elif type == "string" and . != "" then {type: "text", text: .}
          else empty end
        | select(.type == "text")
        | .text
      ' 2>/dev/null | sed -n '1p' | cut -c1-120)"
      [[ -n "$text" ]] && echo "[claude] $text" >&2
      ;;
    *'"type":"tool_use"'*|*'"tool_use"'*)
      tool="$(printf '%s' "$line" | jq -r '
        first(
          .. | objects | select(.type? == "tool_use")
          | (.name? // "") as $name
          | select($name != "" and (["Read", "Grep", "Glob", "LS"] | index($name) | not))
          | $name
        ) // empty
      ' 2>/dev/null | cut -c1-80)"
      [[ -n "$tool" ]] && echo "[claude] tool $tool" >&2
      ;;
  esac
}

set +e
run_claude | while IFS= read -r line; do
  cleaned="${line//$'\r'/}"
  cleaned="${cleaned//$'\004'/}"
  [[ -z "$cleaned" || "$cleaned" != \{* ]] && continue
  printf '%s\n' "$cleaned" >> "$json_file"
  print_progress "$cleaned"
done
exit_code=${PIPESTATUS[0]}
set -e

if [[ -s "$stderr_file" ]]; then
  cat "$stderr_file" >&2
fi

if [[ "$exit_code" -ne 0 && ! -s "$json_file" ]]; then
  fail "Claude exited with code $exit_code"
fi

thread_id="$(jq -sr '[.[] | .session_id? // empty] | .[0] // empty' < "$json_file" 2>/dev/null || true)"

jq -sr '
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
' < "$json_file" 2>/dev/null > "$output_path" || true

if [[ ! -s "$output_path" ]]; then
  echo "(no response from claude)" > "$output_path"
fi

if [[ -n "$thread_id" ]]; then
  echo "session_id=$thread_id"
fi
echo "output_path=$output_path"
