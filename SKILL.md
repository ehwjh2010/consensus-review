---
name: claude-consensus
description: Use only when the user explicitly asks Codex to have Claude review a plan, reach consensus with Claude, run Claude consensus, or perform a similar graded Claude plan-review loop before Codex implements or edits files.
---

# Claude Consensus

Use this skill only for explicit requests to send a Codex plan to Claude for independent graded review and consensus. Do not trigger it for ordinary planning, code review, or implementation requests unless the user clearly asks for Claude to be involved.

## Isolation Model

One user requirement maps to exactly one fresh consensus subagent and one new Claude session.

- The main Codex agent writes the initial plan.
- The main Codex agent creates a fresh subagent for the current requirement.
- The subagent starts a new Claude session on its first review call by omitting `--session`.
- The subagent may reuse the returned Claude `session_id` only inside that same subagent and only for the same requirement.
- A new requirement must create a new subagent and a new Claude session.
- Never reuse an old consensus subagent or old Claude session for a different requirement.
- The main Codex agent must not store, restore, or reuse Claude session ids.
- Claude session ids stay inside the consensus subagent and are not returned for main-agent reuse.
- No `run_id`, manifest, or runtime index is needed. `.runtime/` only stores response markdown files.

## Main Codex Workflow

1. Read enough local context to write an initial implementation plan.
2. Spawn a fresh subagent without unrelated historical context.
3. Give the subagent only the current requirement context:
   - Original user request.
   - Initial Codex plan.
   - Workspace path.
   - Relevant constraints.
   - Any known assumptions.
4. Wait for the subagent to return the final plan, decision status, and any notes or unresolved blockers.
5. If the status is executable, implement or edit files according to the final plan and the user's original request.
6. If the status is blocked, report the blocker or ask the user for the missing decision.

The main Codex agent should not call Claude directly for the consensus loop. The subagent owns the Claude session lifecycle.

## Consensus Subagent Workflow

Use `scripts/ask_claude_consensus.sh` on Unix-like systems or `scripts/ask_claude_consensus.ps1` on PowerShell hosts.

1. Start with the initial plan from the main Codex agent.
2. Round 1: call the script without `--session`.
3. Save the `session_id=...` printed by the script for this requirement only.
4. Read the generated `output_path=...` markdown.
5. Normalize Claude's first meaningful status line before branching:
   - Strip leading whitespace.
   - Strip common markdown wrappers or heading markers such as `**APPROVED**`, `# REVISE`, and `BLOCKED:`.
   - Treat only normalized `APPROVED`, `APPROVED_WITH_NOTES`, `REVISE`, or `BLOCKED` as status tokens; preserve the full markdown body for human review.
6. If the normalized status is `APPROVED`, return the final plan to the main Codex agent for execution.
7. If the normalized status is `APPROVED_WITH_NOTES`, incorporate or explicitly defer the notes, then run another review round with the same `--session`. The final executable status must be `APPROVED`.
8. If the normalized status is `REVISE`, judge the feedback, revise the plan, and run another review round with the same `--session`.
9. If the normalized status is `BLOCKED`, do not invent missing facts. Return the blocker and the best current plan to the main Codex agent so it can ask the user or report why execution cannot proceed.
10. If no status token is clear, ask Claude to restate the decision with a valid first status line and continue the same round count.
11. Stop after `APPROVED`, `BLOCKED`, or 8 total rounds.
12. If the 8-round limit is reached, return the best revised plan and list unresolved disagreements or risks.

Claude is read-only in this workflow. Claude reviews plans, independently explores the workspace for the context required by the current requirement, asks blocking questions, identifies incorrect assumptions, and calls out missing context or test gaps. Claude must not edit files.

## Claude Review Contract

Ask Claude to answer with one of these first-line status tokens. The first non-empty line must be exactly one token, with no markdown formatting, heading marker, prefix, or suffix:

```text
APPROVED
<brief rationale, optional>
```

Use `APPROVED` when the plan is executable as written and covers the important risks.

```text
APPROVED_WITH_NOTES
- <note, caveat, or optional improvement that should be incorporated or explicitly deferred>
```

Use `APPROVED_WITH_NOTES` when the plan is close to executable, but Claude found caveats, lower-risk improvements, or cleanup that Codex should incorporate or explicitly defer before another review round. This is not a final approval state.

```text
REVISE
- <required plan change, incorrect assumption, missing inspection, or verification gap>
```

Use `REVISE` when Codex can fix the plan without asking the user, then send another review round.

```text
BLOCKED
- <missing user decision, inaccessible required context, or contradiction that prevents reliable execution>
```

Use `BLOCKED` when the task should not proceed until the main Codex agent asks the user or obtains unavailable context.

Claude should separate blocking concerns from non-blocking notes. For file review or document editing requests, a plan that only reports opinions when the user asked for edits should be `REVISE`.

## Script Usage

```bash
./scripts/ask_claude_consensus.sh \
  --workspace /path/to/workspace \
  --task "Original user request" \
  --plan "Current Codex plan" \
  --round 1
```

By default, the scripts run Claude with `--model 'deepseek-v4-pro[1m]'`. Override it with `--model <name>` on Unix-like systems or `-Model <name>` in PowerShell.

For follow-up rounds inside the same consensus subagent and same requirement:

```bash
./scripts/ask_claude_consensus.sh \
  --workspace /path/to/workspace \
  --task "Original user request" \
  --plan "Revised Codex plan" \
  --round 2 \
  --session "$CLAUDE_SESSION_ID"
```

The script prints:

```text
session_id=<claude-session-id>
output_path=<markdown-output-path>
```

## Verification

Recommended static checks:

```bash
./scripts/ask_claude_consensus.sh --help
./scripts/ask_claude_consensus.sh --plan "x"
./scripts/ask_claude_consensus.sh --task "x"
./scripts/ask_claude_consensus.sh --workspace /missing --task "x" --plan "y"
```

When `claude` and `jq` are installed, run a dummy two-round review and confirm:

- Round 1 creates and prints a `session_id`.
- Round 2 reuses that session with `--session`.
- `.runtime/*.md` is generated.

When `pwsh` is installed, also verify PowerShell help and argument validation:

```powershell
./scripts/ask_claude_consensus.ps1 -Help
```
