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

## Installation

### Option A — Claude Code plugin (recommended)

Add this repo as a marketplace, then install the plugin. From inside Claude Code:

```
/plugin marketplace add shahin84/synch
/plugin install synch@synch
```

Updates later are just `/plugin marketplace update synch` — no reinstall dance.

### Option B — manual install

Copy the skill into your Claude Code skills directory. It **must** be named `synch`
(the SKILL.md resolves the bridge relative to its own directory):

```bash
git clone https://github.com/shahin84/synch.git /tmp/synch-repo
mkdir -p ~/.claude/skills
cp -R /tmp/synch-repo/skills/synch ~/.claude/skills/synch
chmod +x ~/.claude/skills/synch/scripts/codex-bridge.sh   # usually already set
```

Restart Claude Code and invoke it with `/synch`.

## Repository layout

| Path | What it is |
|------|------------|
| [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json) | Marketplace catalog (for `/plugin marketplace add`) |
| [`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) | Plugin manifest |
| [`skills/synch/SKILL.md`](skills/synch/SKILL.md) | The skill playbook Claude follows |
| [`skills/synch/README.md`](skills/synch/README.md) | Full usage, modes, and how it works |
| [`skills/synch/scripts/codex-bridge.sh`](skills/synch/scripts/codex-bridge.sh) | The bash bridge that pins + resumes the Codex session |
| [`docs/`](docs/) | Design spec |

See **[skills/synch/README.md](skills/synch/README.md)** for the full details.
