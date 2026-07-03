# Synch — Claude ↔ Codex Automatic Collaboration Skill

**Date:** 2026-07-03
**Status:** Design (awaiting user review)
**Skill name / trigger:** `synch` → `/synch`

## Overview

Synch is a Claude Code skill that runs an **automatic back-and-forth loop** between
this live Claude session and the OpenAI Codex CLI. Instead of the user copy-pasting
messages between two tools, Claude composes each of its turns, sends them to Codex via a
thin bridge, reads the reply, narrates it, and continues — pausing at defined checkpoints.

It supersedes ad-hoc use of the existing one-shot `codex` skill by adding a *conversation
loop* with selectable interaction modes, safety checkpoints, and a saved transcript.

## Goals

- One skill, four selectable **modes**: `debate`, `review`, `delegate`, `chat`.
- **Auto with checkpoints**: run turns automatically, but pause (a) before Codex is
  allowed to modify files and (b) every N rounds.
- **Live narration + saved transcript**: condense each turn to the terminal as it happens,
  and persist the full exchange to a markdown file.
- Match existing skill conventions (`codex`, `gemini`) — Claude drives, Codex is reached
  over bash.

## Non-goals (YAGNI)

- No web UI, no MCP server, no Claude Code Channels.
- No separate headless `claude -p` process — the "Claude voice" is *this* session, so it
  keeps full conversation context and can call `AskUserQuestion` for checkpoints.
- No support for models other than Codex/GPT (Gemini is covered by its own skill).
- Codex is never granted `danger-full-access`; `workspace-write` is the ceiling.

## Architecture (Approach C: Claude orchestrates, thin bridge for Codex plumbing)

```
┌────────────────────────────────────────────────────────────┐
│  This Claude Code session  (orchestrator + "Claude" voice)  │
│                                                             │
│  compose turn ─► codex-bridge.sh ─► codex exec / resume     │
│       ▲                │                    │               │
│       │            append turn          Codex reply         │
│       │            to transcript            │               │
│       └──── narrate + assess ◄──────────────┘               │
│                                                             │
│  checkpoints via AskUserQuestion (before writes; every N)   │
└────────────────────────────────────────────────────────────┘
```

- **Claude** holds the user's real goal and full context; it generates every Claude turn
  with its own reasoning and decides when the loop has converged.
- **Codex** keeps its own session across turns, **pinned by session id** (not `--last`).
  Turn 1 runs `codex exec --json` and the bridge captures the session UUID from the
  `session_meta` event; every later turn runs `codex exec resume <UUID>`. This makes the
  loop thread-safe: a second concurrent Synch run, or a standalone `codex` invocation in
  between, cannot hijack the thread the way `resume --last` would. Each run stores its id in
  its own run directory, so runs never collide.

## Components / deliverables

**Project root:** `/Users/shahin/Work/Shahin/AI/synch/`

Source is developed in the project and the skill is **linked into** `~/.claude/skills/synch/`
to activate it (symlink `~/.claude/skills/synch` → `<project>/skill`, so edits in the repo
take effect immediately). Layout:

```
/Users/shahin/Work/Shahin/AI/synch/
├── docs/superpowers/specs/2026-07-03-synch-design.md   # this spec
├── skill/
│   ├── SKILL.md
│   ├── scripts/codex-bridge.sh
│   └── README.md
└── .gitignore                                          # ignores .synch/ transcript dir
```

The skill files:

1. **`skill/SKILL.md`** — the playbook. Frontmatter (`name`, `description`, `trigger`) plus
   sections: invocation & args, the four modes, the turn loop, checkpoint rules, transcript
   format, termination/convergence, error handling, safety.
2. **`skill/scripts/codex-bridge.sh`** — thin helper (~40 lines), executable. Removes the
   repetitive, drift-prone plumbing from every turn.
3. **`skill/README.md`** — short human-facing usage doc (mirrors the existing `codex` skill).

### `codex-bridge.sh` contract

```
codex-bridge.sh --run-dir <dir> --sandbox <read-only|workspace-write> \
                [--model <MODEL>] [--effort <low|medium|high|xhigh>] \
                [--speaker <label>]      # e.g. "Claude → Codex"
# message text is read from STDIN
```

`--run-dir` is the per-run directory (e.g. `./.synch/<timestamp>-<mode>/`) holding
`transcript.md`, a `session-id` file, and a scratch `reply.txt`/`events.jsonl`.

Behavior:
1. Detect first-vs-later turn by whether `<run-dir>/session-id` exists.
   - **First turn:** `codex exec --skip-git-repo-check --sandbox <mode> -m <model> \
     --config model_reasoning_effort="<effort>" --json -o <run-dir>/reply.txt 2>/dev/null`
     (message on stdin). Capture the session UUID from the JSONL stream
     (`grep -oE '"session_id":\s*"[0-9a-f-]{36}"'`, first match) and write it to
     `<run-dir>/session-id`.
   - **Later turns:** `codex exec --skip-git-repo-check resume "$(cat <run-dir>/session-id)" \
     --json -o <run-dir>/reply.txt 2>/dev/null` (message on stdin; no model/effort flags on
     resume — inherits the original session settings).
2. Wrap the call in `timeout` (default 300s).
3. The clean final reply is read from `<run-dir>/reply.txt` (the `--json` stdout is only
   parsed for the session id and otherwise discarded — never shown to the user).
4. Append a formatted turn block (see transcript format) to `<run-dir>/transcript.md`.
5. Print **only Codex's reply** to stdout for Claude to read.
6. Exit non-zero (and echo stderr) on Codex failure so Claude can stop and report.

**Session-id capture — three sources, in order (verified during implementation):**
1. With `-o`, `codex exec` prints its banner (including `session id: <uuid>`) to **stderr**,
   not stdout. The bridge greps the captured stderr (then stdout as backup) with `-h` (so a
   file-path prefix can't leak a UUID) and a **strict** UUID pattern
   `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}` (a loose `{36}` pattern
   wrongly matched timestamp fragments in a filename).
2. A `"session_id":"<uuid>"` field if `--json` is used.
3. Fallback: the newest `~/.codex/sessions/**/rollout-*.jsonl`; its filename's trailing UUID
   equals `payload.session_id`.

The clean reply always comes from `-o reply.txt`, never from this banner/stream. Verified:
a two-turn smoke test captured a clean session id and turn 2 recalled turn-1 state via
`resume <uuid>`.

## Modes

All four share the same loop; they differ only in prompt framing, sandbox, and stop
condition.

| Mode       | Sandbox for Codex | Who edits files | Stop condition |
|------------|-------------------|-----------------|----------------|
| `debate`   | read-only         | nobody          | Claude judges convergence, or cap |
| `review`   | read-only         | **Claude only** | Codex signs off ("no issues"), or cap |
| `delegate` | workspace-write*  | Codex (gated)   | subtasks done + Claude verifies, or cap |
| `chat`     | read-only         | nobody          | cap or user stops at a checkpoint |

\* `delegate` is the only mode where Codex may write; the first write triggers the
"before Codex edits" checkpoint to approve `workspace-write`.

- **`debate`** — Claude states a position; Codex critiques/counters; Claude revises.
  Output: agreed conclusion plus any remaining dissent.
- **`review`** (build→review) — Claude writes/edits code with its own tools; Codex reviews
  read-only; Claude applies fixes; repeat until sign-off or cap. Claude always holds the pen.
- **`delegate`** — Claude splits work into subtasks and hands each to Codex, integrating
  and verifying results. Write access is checkpoint-gated.
- **`chat`** (open pair) — free-form back-and-forth on a seeded topic; read-only.

## Invocation & arguments

```
/synch <mode> "<task or topic>" [--rounds N] [--model <id>] [--effort <level>] [--write]
```

- `mode` ∈ {`debate`, `review`, `delegate`, `chat`}. If omitted, ask via `AskUserQuestion`.
- `"<task or topic>"` — the seed. If omitted, ask.
- **Model, effort, and round cap are chosen interactively at startup** (see *Session
  initialization* below). The flags below are optional overrides that *skip* the
  corresponding prompt:
  - `--rounds N` — hard cap on Claude↔Codex round-trips (skips the rounds prompt; default 6).
  - `--model <id>` — Codex model (skips the model prompt).
  - `--effort <level>` — reasoning effort (skips the effort prompt).
- `--write` — pre-authorize Codex `workspace-write` (still checkpointed on first write).

## Session initialization (config negotiation)

Before the loop starts, the skill negotiates the Codex configuration for the whole thread:

1. **Probe Codex for its current config.** Read `~/.codex/config.toml` for `model` and
   `model_reasoning_effort` (fast, no API call). These are the *detected defaults*.
   > Reality check: the Codex CLI has **no command to enumerate the full model catalog**,
   > and it does not validate the effort value. So "available models" means the detected
   > current model plus a curated pick-list — not a live catalog.
2. **Ask the user (via `AskUserQuestion`), unless a flag already supplied the value:**
   - **Model** — options: the detected current model (marked *Recommended*), a curated list
     of known Codex model ids (e.g. `gpt-5.5`, `gpt-5.2`, `gpt-5.2-max`, `gpt-5.2-mini`,
     `gpt-5.1-thinking`), and free-text "Other" for custom providers (e.g. `omlx`).
   - **Reasoning effort** — options: `minimal`, `low`, `medium`, `high`, `xhigh` (detected
     current marked *Recommended*).
   - **Round cap** — options: `4`, `6` (*Recommended / default*), `8`, `10`, plus "Other".
3. **Lock the config for the thread.** The chosen `model` + `effort` are applied on **turn 1**
   (`-m <model> -c model_reasoning_effort="<effort>"`). Because the session is pinned and
   later turns use `resume <UUID>` (which inherits the original session's settings), the
   config persists for every subsequent turn automatically — it is set once, not per turn.

## The turn loop

```
0. Resolve mode + task (AskUserQuestion if missing).
1. SESSION INITIALIZATION — probe Codex config, then ask model / effort / round cap
   (see "Session initialization" above). These are locked for the whole thread.
2. Create run dir ./.synch/<timestamp>-<mode>/ and write transcript.md header
   (records the chosen model, effort, cap). The bridge pins the Codex session id into
   <run-dir>/session-id on turn 1; the chosen model+effort are applied on turn 1 only and
   inherited by every resume thereafter.
3. round = 0
4. LOOP:
     a. Claude composes its turn (reasoning tailored to the mode).
     b. If this turn requires Codex to WRITE and write is not yet approved → CHECKPOINT.
     c. Pipe the turn through codex-bridge.sh --run-dir <run-dir> (correct sandbox).
     d. Read Codex's reply; narrate a condensed version live; transcript already appended.
     e. round += 1
     f. Assess termination (mode-specific convergence OR round == cap).
        - If terminated → break.
     g. If round % N == 0 (N default 3) → CHECKPOINT (continue / redirect / stop).
5. Produce a final synthesis and print the transcript path.
```

## Checkpoints ("auto with checkpoints")

Both are `AskUserQuestion` prompts offering **continue / redirect / stop**:

1. **Before Codex writes files** — fires the first time a mode (i.e. `delegate`) needs
   `workspace-write`. Never run Codex in write mode without this approval.
2. **Every N rounds** — default N = 3 — to approve, redirect the direction, or stop early.

## Transcript format

Path: `./.synch/<timestamp>-<mode>/transcript.md` in the working directory (each run gets
its own directory alongside `session-id` and scratch files; add `.synch/` to `.gitignore`).
Timestamp comes from bash `date` at runtime.

```markdown
# Synch transcript — <mode> — <timestamp>
**Task:** <seed>  ·  **Model:** <model>  ·  **Effort:** <effort>  ·  **Cap:** <rounds>

## Round 1
### Claude → Codex
<full Claude message>
### Codex → Claude
<full Codex reply>

## Round 2
...

## Outcome
<final synthesis / consensus / sign-off>
```

## Termination & convergence

- **`debate`** — Claude declares convergence when both sides agree (or the remaining
  disagreement is explicitly noted as irreconcilable).
- **`review`** — Codex explicitly reports "no issues" (sign-off).
- **`delegate`** — all subtasks returned and Claude has verified them.
- **`chat`** — user stop, or cap.
- **All modes** — hard stop at the round cap. On cap-without-convergence, summarize the
  divergence and offer to extend by N more rounds.

## Error handling

- `codex` missing or version too old → stop, report, do not loop.
- `codex exec` non-zero exit → surface stderr, stop, ask via `AskUserQuestion`.
- Empty reply or hang → timeout guard (default 300s), one retry, then checkpoint.
  **Portability:** `timeout` is *not* present on stock macOS. The bridge probes for
  `timeout`, then `gtimeout` (coreutils); if neither exists it runs without a hard timeout
  (or uses a background-PID + `kill` fallback). Never assume `timeout` exists.
- **Output noise:** plain `codex exec` stdout carries a header block, `hook: SessionStart`
  lines, and MCP `AuthorizationRequired` errors from unrelated Codex-configured MCP servers.
  The clean final reply is always taken from `-o <run-dir>/reply.txt`, never scraped from
  raw stdout; these noise lines are ignored.
- No convergence by cap → summarize divergence; offer to extend.
- Codex is never run in write mode without the write checkpoint; `danger-full-access`
  is never used.

## Safety

- Read-only is the default sandbox for every mode except an approved `delegate` write.
- `--skip-git-repo-check` is used (consistent with the existing `codex` skill).
- High-impact escalation is capped at `workspace-write`, always behind a checkpoint.

## Testing plan

1. **Config negotiation** — at startup the skill detects Codex's current model/effort,
   asks model + effort + round cap, and the chosen model appears in the turn-1 `codex exec`
   header and still governs later `resume` turns (config set once, persists for the thread).
2. **Smoke** — `chat` mode, 1 round, trivial topic: bridge round-trips, `session-id` is
   captured, and transcript is written with both sides.
3. **Session pinning** — turn 2 references something only stated in turn 1 (confirms Codex
   continuity via `resume <UUID>`, not `--last`).
4. **Cross-run isolation** — start Synch run A (turn 1), then run a *separate* `codex exec`
   (or Synch run B) so it becomes the global "last" session, then continue run A: run A must
   still resume its own pinned id, not the intervening session.
5. **Write checkpoint** — `delegate` mode pauses before Codex's first edit.
6. **Cap** — loop stops exactly at `--rounds`.
7. **Read-only enforcement** — in `debate`/`review`/`chat`, Codex cannot modify files.

## Defaults chosen (easy to change)

- Skill name / trigger: `synch` / `/synch`.
- **Model + effort + round cap are chosen by the user at startup** (Session initialization),
  not hardcoded. Defaults offered: model/effort = whatever Codex reports as current
  (`config.toml`); round cap default = **6**.
- Checkpoint every 3 rounds; timeout 300s (via `timeout`/`gtimeout` if available).
- Transcript dir: `./.synch/` (gitignored).

## Open questions

- Skill name `synch` — **confirmed by user** (Marvel X-Men theme: the mutant who
  synchronizes with others to share their abilities).
- Confirm transcript directory location (`./.synch/` vs the session scratchpad).
