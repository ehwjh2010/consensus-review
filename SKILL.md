---
name: claude-consensus
description: Use only when the user explicitly asks Codex to have Claude review a plan, reach consensus with Claude, run Claude consensus, or perform a similar Claude plan-review loop before implementation.
---

# Claude Consensus

Use this skill only for explicit requests to send a Codex plan to Claude for independent review and consensus. Do not trigger it for ordinary planning, code review, or implementation requests unless the user clearly asks for Claude to be involved.

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
4. Wait for the subagent to return the final plan that Claude agreed with, or the best revised plan plus unresolved disagreements if consensus was not reached.
5. Present the returned plan to the user inside `<proposed_plan>...</proposed_plan>`.

The main Codex agent should not call Claude directly for the consensus loop. The subagent owns the Claude session lifecycle.

## Consensus Subagent Workflow

Use `scripts/ask_claude_consensus.sh` on Unix-like systems or `scripts/ask_claude_consensus.ps1` on PowerShell hosts.

1. Start with the initial plan from the main Codex agent.
2. Round 1: call the script without `--session`.
3. Save the `session_id=...` printed by the script for this requirement only.
4. Read the generated `output_path=...` markdown.
5. Normalize Claude's first meaningful status line before branching:
   - Strip leading whitespace.
   - Strip common markdown wrappers or heading markers such as `**AGREE**`, `**ISSUES**`, `# AGREE`, `## ISSUES`, and `AGREE:`.
   - Treat only normalized `AGREE` or `ISSUES` as status tokens; preserve the full markdown body for human review.
6. If the normalized status is `AGREE`, return the agreed plan to the main Codex agent.
7. If the normalized status is `ISSUES`, judge the feedback, revise the plan, and run another review round with the same `--session`.
8. If no status token is clear, treat the response as `ISSUES` and revise the plan or ask Claude to restate the blocking issues with a valid first status line.
9. Stop after Claude returns `AGREE` or after 8 total rounds.
10. If the 8-round limit is reached, return the best revised plan and list unresolved disagreements or risks.

Claude is read-only in this workflow. Claude reviews plans, independently explores the workspace for the context required by the current requirement, asks blocking questions, identifies incorrect assumptions, and calls out missing context or test gaps. Claude must not edit files.

## Claude Review Contract

Ask Claude to answer in one of these forms. The first non-empty line must be exactly `AGREE` or `ISSUES`, with no markdown formatting, heading marker, prefix, or suffix:

```text
AGREE
<brief rationale, optional>
```

or:

```text
ISSUES
- <blocking issue, incorrect assumption, missing context, or test gap>
```

Claude should list only issues that materially affect whether the plan can be executed correctly.

## Script Usage

```bash
./scripts/ask_claude_consensus.sh \
  --workspace /path/to/workspace \
  --task "Original user request" \
  --plan "Current Codex plan" \
  --round 1
```

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
