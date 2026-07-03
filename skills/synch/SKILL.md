---
name: synch
description: Run an automatic back-and-forth loop between Claude and the OpenAI Codex CLI. Use when the user asks to have Claude and Codex collaborate, debate, cross-review, delegate, or pair-program on a task (triggers include "/synch", "have codex and claude work together", "debate this with codex", "get codex to review this with you"). Four modes — debate, review, delegate, chat. Runs automatically with checkpoints and saves a full transcript.
---

# Synch — Claude ↔ Codex automatic collaboration

Synch makes **this** Claude session talk to the OpenAI Codex CLI in an automatic loop.
You (Claude) are BOTH the orchestrator and the "Claude" voice: you compose every Claude
turn with your own reasoning, send it to Codex through the bridge script, read Codex's
reply, narrate a condensed version to the user, and continue — pausing at checkpoints.
Codex is reached over bash and its session is **pinned by id** so the thread never crosses
with other Codex sessions.

Trigger: `/synch <mode> "<task>"` — modes: `debate` | `review` | `delegate` | `chat`.

---

## 0. Preflight

- Confirm Codex exists: run `codex --version`. If missing → stop and tell the user to
  install it (`npm install -g @openai/codex` + `codex login`).
- The bridge script lives at `scripts/codex-bridge.sh` inside **this skill's own directory**.
  Resolve its absolute path from the skill's base directory — the "Base directory for this skill"
  that is announced when this skill is invoked — and set `BRIDGE="<that base directory>/scripts/codex-bridge.sh"`.
  Use `BRIDGE` in every call.
  - Manual install (`~/.claude/skills/synch/`) → `BRIDGE="$HOME/.claude/skills/synch/scripts/codex-bridge.sh"`.
  - Plugin install → `BRIDGE="${CLAUDE_PLUGIN_ROOT}/skills/synch/scripts/codex-bridge.sh"`.
  Do NOT hardcode a single path blindly: confirm it exists with `ls -l "$BRIDGE"` before the loop;
  if it's missing, stop and tell the user the skill isn't installed correctly.

## 1. Resolve mode + task

- `mode` ∈ {debate, review, delegate, chat}. If missing or ambiguous → `AskUserQuestion`.
- `task` = the seed text/topic. If missing → `AskUserQuestion`.
- Optional flags on the invocation: `--rounds N`, `--model <id>`, `--effort <level>`,
  `--write`. Each flag SKIPS the matching prompt in step 2.

## 2. Session initialization (config negotiation) — always run before looping

a. **Probe Codex's current config** (no API call):
   `grep -E '^(model|model_reasoning_effort)' ~/.codex/config.toml 2>/dev/null`
   Use those as the detected defaults. If absent, default to `gpt-5.2` / `medium`.
b. **Ask the user** with `AskUserQuestion` (skip any value already given as a flag):
   - **Model** — options: the detected current model labelled "(Recommended)", plus
     `gpt-5.5`, `gpt-5.2`, `gpt-5.2-max`, `gpt-5.2-mini`, `gpt-5.1-thinking`. The built-in
     "Other" lets the user type a custom id (e.g. a custom provider model).
   - **Reasoning effort** — options: `minimal`, `low`, `medium`, `high`, `xhigh`
     (detected one labelled "(Recommended)").
   - **Round cap** — options: `6` "(Recommended)", `4`, `8`, `10`, plus "Other". Default 6.
   > Honesty note: the Codex CLI has NO command to enumerate its full model catalog, and it
   > does not validate the effort value. This curated list + free-text override IS the
   > intended behaviour — do not claim to have fetched a live catalog.
c. Remember `MODEL`, `EFFORT`, `ROUNDS` for the whole run. They are applied on turn 1 only
   and inherited by every later turn (the bridge pins + resumes the session).

## 3. Create the run

- `RUN_DIR="./.synch/$(date +%Y-%m-%dT%H-%M-%S)-<mode>"`; `mkdir -p "$RUN_DIR"`.
- Write a transcript header to `$RUN_DIR/transcript.md`:
  ```
  # Synch transcript — <mode> — <timestamp>
  **Task:** <task>  ·  **Model:** <MODEL>  ·  **Effort:** <EFFORT>  ·  **Cap:** <ROUNDS>
  ```
- If a `.gitignore` exists in the working dir and lacks `.synch/`, append `.synch/` to it.

## 4. The loop

Set `round = 1`, `write_approved = false`. Repeat:

1. **Compose Claude's turn** — your own reasoning, framed for the mode (see §5). This exact
   text is sent to Codex, so make it self-contained.
2. **Write checkpoint** — only if this mode/turn needs Codex to modify files (i.e. `delegate`)
   and `write_approved` is false: `AskUserQuestion` → [Approve writes / Keep read-only / Stop].
   Only on approval use `--sandbox workspace-write` and set `write_approved = true`.
   (`--write` at invocation pre-approves, but still confirm the FIRST time.)
3. **Send to Codex via the bridge** (read-only sandbox unless approved writes):
   ```
   printf '%s' "<your turn text>" | bash "$BRIDGE" \
     --run-dir "$RUN_DIR" --sandbox <read-only|workspace-write> \
     --model "<MODEL>" --effort "<EFFORT>" --round "$round" --speaker "Claude → Codex"
   ```
   Pass `--model`/`--effort` on every call; the bridge only applies them on turn 1.
4. **Read Codex's reply** = the bridge's stdout. **Narrate a condensed version** to the user
   (2–5 lines: Codex's key point / verdict / what changed). The full text is already saved
   in the transcript, so don't dump it.
5. **Assess termination** (see §6). If met → break.
6. **Round checkpoint** — if `round % 3 == 0` and not stopping: `AskUserQuestion` →
   [Continue / Redirect / Stop]. On "Redirect", fold the user's guidance into your next turn.
7. `round = round + 1`. If `round > ROUNDS` → stop (cap reached).

## 5. Modes

- **debate** (read-only) — Turn 1: state your position and reasoning. Each turn: engage
  Codex's counterpoints, concede or defend with evidence. Converged when you and Codex
  agree, or when you judge the remaining gap irreconcilable. Output: the agreed answer plus
  any noted dissent.
- **review** (read-only for Codex; YOU hold the pen) — Between turns, YOU write/edit code
  with your own tools, then ask Codex to review the changed files/diff. Apply the fixes it
  raises. Converged when Codex reports no remaining issues (sign-off).
- **delegate** (Codex may write — gated) — You are the PM. Break the task into subtasks and
  hand ONE per turn to Codex with clear acceptance criteria. Codex writing files triggers
  the write checkpoint. Verify each result before handing off the next. Done when all
  subtasks are complete and verified.
- **chat** (read-only) — Free-form pair discussion on the seed topic. Runs until the cap or
  the user stops at a checkpoint.

## 6. Termination

- `debate`: agreement reached. `review`: Codex sign-off. `delegate`: all subtasks verified.
  `chat`: user stop.
- ALL modes: hard stop at the round cap. On cap-without-convergence, summarize the
  divergence and offer to extend by N more rounds (`AskUserQuestion`).

## 7. Finish

- Append an `## Outcome` section to `$RUN_DIR/transcript.md` (consensus / sign-off / results).
- Give the user a final synthesis in the terminal and print the transcript path.

## 8. Errors

- Bridge exits non-zero → it prints the filtered Codex stderr; stop, show the user, and ask
  how to proceed (`AskUserQuestion`).
- Empty reply / hang → the bridge applies a timeout when `timeout`/`gtimeout` is available
  (neither on stock macOS → no hard cap). Retry once, then checkpoint.
- **Never** run Codex with `--sandbox workspace-write` without the write checkpoint. **Never**
  use `danger-full-access`.

## Safety

Read-only is the default for every mode; the only write path is an approved `delegate` turn,
capped at `workspace-write`. `--skip-git-repo-check` is used because Codex often runs outside
a git repo here.
