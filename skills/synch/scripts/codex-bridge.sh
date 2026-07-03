#!/usr/bin/env bash
# codex-bridge.sh — run ONE Claude→Codex turn for the `synch` skill.
#
# Reads the outgoing message from STDIN, sends it to the OpenAI Codex CLI, keeps the
# SAME Codex session across turns by pinning its session id (never `resume --last`),
# appends both sides to the run transcript, and prints Codex's clean reply to STDOUT.
#
# Usage:
#   printf '%s' "<message>" | codex-bridge.sh --run-dir <dir> --sandbox <read-only|workspace-write> \
#       [--model <id>] [--effort <level>] [--round <n>] [--speaker <label>] [--timeout <secs>]
#
# First turn (no <run-dir>/session-id yet): starts a session, applies --model/--effort,
#   and captures the session id into <run-dir>/session-id.
# Later turns: `codex exec resume <id>` — model/effort are inherited, not re-sent.
set -eo pipefail

run_dir=""
sandbox="read-only"
model=""
effort=""
round=""
speaker="Claude → Codex"
timeout_secs=300

while [ $# -gt 0 ]; do
  case "$1" in
    --run-dir) run_dir="$2"; shift 2 ;;
    --sandbox) sandbox="$2"; shift 2 ;;
    --model)   model="$2";   shift 2 ;;
    --effort)  effort="$2";  shift 2 ;;
    --round)   round="$2";   shift 2 ;;
    --speaker) speaker="$2"; shift 2 ;;
    --timeout) timeout_secs="$2"; shift 2 ;;
    *) echo "codex-bridge: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$run_dir" ] || { echo "codex-bridge: --run-dir is required" >&2; exit 2; }
command -v codex >/dev/null 2>&1 || { echo "codex-bridge: codex CLI not found on PATH" >&2; exit 3; }

mkdir -p "$run_dir"
transcript="$run_dir/transcript.md"
sid_file="$run_dir/session-id"
reply_file="$run_dir/reply.txt"
out_log="$run_dir/last-stdout.log"
err_log="$run_dir/last-stderr.log"

# Outgoing message from stdin.
msg="$(cat)"
[ -n "$msg" ] || { echo "codex-bridge: empty message on stdin" >&2; exit 2; }

# macOS has no `timeout`; fall back to `gtimeout`, else run without a hard cap.
timeout_cmd=()
if command -v timeout >/dev/null 2>&1; then
  timeout_cmd=(timeout "$timeout_secs")
elif command -v gtimeout >/dev/null 2>&1; then
  timeout_cmd=(gtimeout "$timeout_secs")
fi

rm -f "$reply_file"

if [ -f "$sid_file" ]; then
  # ---- Later turn: resume the pinned session (settings inherited) ----
  sid="$(cat "$sid_file")"
  first_turn=0
  cmd=(codex exec --skip-git-repo-check resume -o "$reply_file" "$sid" -)
else
  # ---- First turn: start a session and pin its id ----
  first_turn=1
  cmd=(codex exec --skip-git-repo-check --sandbox "$sandbox" -o "$reply_file")
  [ -n "$model" ]  && cmd+=(-m "$model")
  [ -n "$effort" ] && cmd+=(-c "model_reasoning_effort=$effort")
  cmd+=(-)
fi

set +e
printf '%s' "$msg" | "${timeout_cmd[@]}" "${cmd[@]}" >"$out_log" 2>"$err_log"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "codex-bridge: codex exited with status $rc" >&2
  [ -s "$err_log" ] && grep -viE '^hook: |AuthorizationRequired|rmcp::transport' "$err_log" | head -40 >&2
  exit "$rc"
fi

# On the first turn, capture + pin the session id. Three sources, in order.
# Codex prints "session id: <uuid>" to STDERR (with -o); use a strict UUID pattern so we
# never grab a timestamp fragment from a filename.
if [ "$first_turn" -eq 1 ]; then
  uuid='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  # -h so grep never prints the file path (which may itself contain a UUID) as a prefix.
  sid="$(grep -hiE 'session id' "$err_log" "$out_log" 2>/dev/null | grep -oiE "$uuid" | head -1 || true)"
  [ -z "$sid" ] && sid="$(grep -hoiE "\"session_id\"[[:space:]]*:[[:space:]]*\"$uuid\"" "$err_log" "$out_log" 2>/dev/null | grep -oiE "$uuid" | head -1 || true)"
  if [ -z "$sid" ]; then
    newest="$(ls -t "$HOME"/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -1 || true)"
    [ -n "$newest" ] && sid="$(basename "$newest" | grep -oiE "$uuid" | head -1 || true)"
  fi
  if [ -n "$sid" ]; then
    printf '%s' "$sid" > "$sid_file"
  else
    echo "codex-bridge: WARNING could not capture session id — later turns cannot resume this thread" >&2
  fi
fi

# The clean reply is the output-last-message file (never the noisy stdout).
if [ ! -s "$reply_file" ]; then
  echo "codex-bridge: no reply captured (reply.txt empty)" >&2
  exit 1
fi
reply="$(cat "$reply_file")"

# Append this turn to the transcript.
{
  if [ -n "$round" ]; then printf '\n## Round %s\n' "$round"; else printf '\n## Turn\n'; fi
  printf '_%s_\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  printf '### %s\n\n%s\n\n' "$speaker" "$msg"
  printf '### Codex → Claude\n\n%s\n' "$reply"
} >> "$transcript"

# Hand Codex's reply back to Claude.
printf '%s\n' "$reply"
