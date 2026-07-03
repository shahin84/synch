# Synch 🔗 — Claude ↔ Codex automatic collaboration

A Claude Code skill that runs an automatic back-and-forth loop between **Claude Code** and
the **OpenAI Codex CLI**. Claude orchestrates and speaks as itself; Codex is a peer reached
over bash. You watch the narrated exchange live and get a full saved transcript.

> Named after the Marvel X-Men mutant **Synch**, who synchronizes with others to share their abilities.

## Quick start

```
/synch <mode> "<task or topic>" [--rounds N] [--model <id>] [--effort <level>] [--write]
```

| Mode       | What happens                                              | Codex writes? |
|------------|----------------------------------------------------------|---------------|
| `debate`   | Claude and Codex argue a question until they converge     | no            |
| `review`   | Claude writes/edits code; Codex reviews until sign-off    | no            |
| `delegate` | Claude splits work into subtasks and farms them to Codex  | yes (gated)   |
| `chat`     | Free-form pair discussion on a seeded topic              | no            |

## Requirements

- [Claude Code](https://claude.com/claude-code)
- OpenAI Codex CLI: `npm install -g @openai/codex` then `codex login`

## Repository layout

| Path | What it is |
|------|------------|
| [`skill/SKILL.md`](skill/SKILL.md) | The skill playbook Claude follows |
| [`skill/README.md`](skill/README.md) | Full usage, modes, and how it works |
| [`skill/scripts/codex-bridge.sh`](skill/scripts/codex-bridge.sh) | The bash bridge that pins + resumes the Codex session |
| [`docs/`](docs/) | Design spec |

See **[skill/README.md](skill/README.md)** for the full details.
