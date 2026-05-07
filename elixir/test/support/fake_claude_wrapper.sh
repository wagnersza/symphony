#!/usr/bin/env bash
# Fake Claude wrapper for Symphony Elixir tests.
# Behavior is keyed on the FAKE_WRAPPER_MODE env var.
#
# Modes:
#   ready      — emit {"event":"ready"} and then wait on stdin; echo session_end on EOF/stop.
#   happy_path — emit ready, then on each stdin {"type":"start",...} emit a full turn and exit on stop.
#   startup_fail — emit nothing, exit 17.
#
# All emitted JSON lines use a fixed timestamp so tests can assert exact output.

set -euo pipefail

emit() {
  printf '%s\n' "$1"
}

mode="${FAKE_WRAPPER_MODE:-happy_path}"

case "$mode" in
  startup_fail)
    echo "simulated startup failure" >&2
    exit 17
    ;;
esac

emit '{"event":"ready","timestamp":"2026-05-07T20:00:00Z"}'

while IFS= read -r line; do
  case "$line" in
    *'"type":"start"'*)
      emit '{"event":"turn_start","turn":1,"timestamp":"2026-05-07T20:00:01Z"}'
      emit '{"event":"tool_call","tool":"Read","args":{"path":"lib/foo.ex"},"tool_call_id":"tc_1","timestamp":"2026-05-07T20:00:02Z"}'
      emit '{"event":"tool_result","tool":"Read","ok":true,"exit":null,"output":"contents","tool_call_id":"tc_1","timestamp":"2026-05-07T20:00:03Z"}'
      emit '{"event":"message","text":"done","timestamp":"2026-05-07T20:00:04Z"}'
      emit '{"event":"tokens","input":10,"output":5,"total":15,"timestamp":"2026-05-07T20:00:05Z"}'
      emit '{"event":"turn_end","turn":1,"session_id":"sess_fake_1","timestamp":"2026-05-07T20:00:06Z"}'
      ;;
    *'"type":"stop"'*)
      emit '{"event":"session_end","reason":"completed","detail":null,"timestamp":"2026-05-07T20:00:07Z"}'
      exit 0
      ;;
  esac
done

emit '{"event":"session_end","reason":"completed","detail":null,"timestamp":"2026-05-07T20:00:08Z"}'
exit 0
