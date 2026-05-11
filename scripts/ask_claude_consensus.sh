#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ask_claude_consensus.sh --input-kind <plan|file> [options]

First round required:
  -t, --task <text>            Original user request or requirement
  -p, --plan <text>            Initial Codex plan or file review instructions

Consensus:
      --input-kind <kind>      Internal input kind: plan or file (default: plan)
      --round <n>              Review round number (default: 1)
      --session <id>           Resume the Claude session for this same requirement

Options:
  -w, --workspace <path>       Workspace directory (default: current directory)
      --target <path>          Target file/path for file input (repeatable)
      --verification <text>    Optional verification commands/results
      --verification-file <path>
                               Read optional verification commands/results from file
      --model <name>           Claude model (default: use Claude CLI default)
      --effort <level>         Effort: low, medium, high, max (default: max)
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

read_text_file() {
  local option="$1" path="$2"
  [[ -f "$path" ]] || fail "$option file does not exist: $path"
  < "$path"
}

workspace="${PWD}"
task_text=""
plan_text=""
input_kind="plan"
target_paths=()
verification_text=""
round="1"
model=""
effort="max"
permission_mode="plan"
output_path=""
session_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace) workspace="$(take_value "$1" "${2:-}")"; shift 2 ;;
    -t|--task) task_text="$(take_value "$1" "${2:-}")"; shift 2 ;;
    -p|--plan) plan_text="$(take_value "$1" "${2:-}")"; shift 2 ;;
    --input-kind) input_kind="$(take_value "$1" "${2:-}")"; shift 2 ;;
    --target) target_paths+=("$(take_value "$1" "${2:-}")"); shift 2 ;;
    --verification) verification_text="$(take_value "$1" "${2:-}")"; shift 2 ;;
    --verification-file) verification_text="$(read_text_file "$1" "$(take_value "$1" "${2:-}")")"; shift 2 ;;
    --round) round="$(take_value "$1" "${2:-}")"; shift 2 ;;
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
input_kind="$(trim_whitespace "$input_kind")"
round="$(trim_whitespace "$round")"

case "$input_kind" in
  plan|file) ;;
  *) fail "--input-kind must be one of: plan, file." ;;
esac
if [[ "$input_kind" == "file" && "${#target_paths[@]}" -eq 0 ]]; then
  fail "--target is required for --input-kind file."
fi
if [[ -z "$session_id" ]]; then
  [[ -n "$task_text" ]] || fail "Missing required --task."
  [[ -n "$plan_text" ]] || fail "Missing required --plan."
elif [[ "$input_kind" == "plan" ]]; then
  [[ -n "$plan_text" ]] || fail "Missing required --plan for resumed plan review."
fi
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

resolve_target() {
  local path="$1" dir base
  [[ -e "$path" ]] || fail "Target path does not exist: $path"
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd)
  else
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    printf '%s/%s\n' "$(cd "$dir" && pwd)" "$base"
  fi
}

target_section="(none)"
if [[ "${#target_paths[@]}" -gt 0 ]]; then
  target_section=""
  for target_path in "${target_paths[@]}"; do
    target_section+="- $(resolve_target "$target_path")"$'\n'
  done
  target_section="${target_section%$'\n'}"
fi

status_contract="$(cat <<'CONTRACT'
Review contract:
- The first non-empty line of your response must be exactly one of: APPROVED, APPROVED_WITH_NOTES, REVISE, BLOCKED.
- Do not wrap the status token in markdown, headings, punctuation, prefixes, or suffixes.
- Return APPROVED if the submitted plan is a complete acceptable plan, or the target file content is acceptable as written, and the important risks are covered.
- Return APPROVED_WITH_NOTES if the work is close but has caveats, lower-risk improvements, or cleanup that the Codex subagent should incorporate into the plan or target files when appropriate, or explicitly defer before another review round. For plan input, the subagent will send the complete updated plan in the next round.
- Return REVISE if the Codex subagent should change the plan or target files, but can do so without asking the user. For plan input, the subagent will send the complete updated plan in the next round.
- Return BLOCKED if execution needs a missing user decision, inaccessible required context, or resolution of a contradiction.
- Separate blocking concerns from non-blocking notes.
- Make REVISE and APPROVED_WITH_NOTES feedback concrete enough for a Codex subagent to turn into edits, deferrals, or verification steps.
- Do not edit files. Do not propose unrelated improvements.
CONTRACT
)"

verification_section=""
if [[ -n "$verification_text" ]]; then
  verification_section="$(cat <<VERIFY

Verification:
$verification_text
VERIFY
)"
fi

if [[ -n "$session_id" && "$input_kind" == "plan" ]]; then
  prompt="$(cat <<PROMPT
You are Claude reviewing Codex work in read-only mode.

$status_contract

Consensus round:
$round

Updated plan:
$plan_text
PROMPT
)"
elif [[ -n "$session_id" && "$input_kind" == "file" ]]; then
  prompt="$(cat <<PROMPT
You are Claude reviewing Codex work in read-only mode.

$status_contract

Consensus round:
$round

Target files/paths:
$target_section

The target files have changed. Based on the current file contents and the prior session context, review them again.
PROMPT
)"
else
  prompt="$(cat <<PROMPT
You are Claude reviewing Codex work in read-only mode.

$status_contract
- Use the resumed session context from prior rounds when it already contains the needed code, configuration, tests, and documentation.
- On round 1, build enough workspace context to review reliably.
- For plan input, review the current Codex plan.
- For file input, the target files/paths are the source of truth; inspect them as needed and identify the affected location, problem, and expected result when requesting changes.
- Choose any additional relevant paths yourself from the user request, input kind, targets, and current plan.

Workspace:
$workspace

Consensus round:
$round

Input kind:
$input_kind

Target files/paths:
$target_section

Original user request:
$task_text

Initial Codex plan or file review instructions:
$plan_text$verification_section
PROMPT
)"
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
