# Synch 🔗 — Claude ↔ Codex automatic collaboration

Run an automatic back-and-forth loop between Claude Code and the OpenAI Codex CLI. Claude
orchestrates and speaks as itself; Codex is a peer reached over bash. You watch the narrated
exchange live and get a full saved transcript.

Named after the Marvel X-Men mutant **Synch**, who synchronizes with others to share their
abilities.

## Requirements

- Claude Code
- OpenAI Codex CLI: `npm install -g @openai/codex` then `codex login`

## Usage

```
/synch <mode> "<task or topic>" [--rounds N] [--model <id>] [--effort <level>] [--write]
```

Modes:

| Mode       | What happens                                                        | Codex writes? |
|------------|--------------------------------------------------------------------|---------------|
| `debate`   | Claude and Codex argue a question until they converge               | no            |
| `review`   | Claude writes/edits code; Codex reviews until sign-off              | no            |
| `delegate` | Claude splits work into subtasks and farms them to Codex            | yes (gated)   |
| `chat`     | Free-form pair discussion on a seeded topic                        | no            |

Examples:

```
/synch debate "Postgres or DynamoDB for the events table?"
/synch review "the auth refactor I just made"
/synch delegate "add pagination to the /orders endpoint and its tests"
/synch chat "brainstorm names for this feature"
```

## How it works

1. **Startup** — Synch reads Codex's current model/effort from `~/.codex/config.toml` and
   asks you which **model**, **effort**, and **round cap** to use (default 6). The Codex CLI
   can't list a full model catalog, so you get the detected model plus a curated pick-list
   and a free-text option.
2. **Config is locked for the thread** — applied on turn 1 and inherited by every later turn.
3. **The loop** — Claude composes a turn → the bridge sends it to Codex → Claude reads and
   narrates the reply → repeat. It pauses **before Codex ever writes files** and **every 3
   rounds** so you can continue, redirect, or stop.
4. **Session pinning** — Codex's session id is captured on turn 1 and resumed by that exact
   id (`resume <id>`, never `resume --last`), so concurrent Synch runs or other `codex` usage
   can't hijack the thread.

## Output

Each run writes to `./.synch/<timestamp>-<mode>/` in the working directory:

- `transcript.md` — the full Claude↔Codex exchange plus the final outcome
- `session-id` — the pinned Codex session id
- `reply.txt`, `last-stdout.log`, `last-stderr.log` — per-turn scratch

Add `.synch/` to your `.gitignore` (Synch does this automatically if a `.gitignore` exists).

## Files

- `SKILL.md` — the playbook Claude follows
- `scripts/codex-bridge.sh` — runs one Claude→Codex turn (session pinning, transcript, clean reply)
