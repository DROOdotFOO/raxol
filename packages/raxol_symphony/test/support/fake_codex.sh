#!/usr/bin/env bash
# Fake Codex app-server. Reads JSON-RPC requests on stdin and emits scripted
# responses on stdout. Used by tests of Raxol.Symphony.Runners.Codex.
#
# Mode is selected via FAKE_CODEX_MODE env var:
#   happy     -- one-turn happy path with text_delta + turn/completed (default)
#   multi     -- emits two turn/completed events (for continuation tests)
#   tool      -- emits an item/tool/call mid-turn
#   approval  -- emits item/commandExecution/requestApproval mid-turn
#   fail      -- emits turn/failed instead of turn/completed
#   hang      -- never responds after thread/start (timeout tests)
#
# All output uses bash builtins (printf / echo / read) which write directly
# via write(2), bypassing libc stdio buffering. Do NOT introduce pipes.

set -u

mode="${FAKE_CODEX_MODE:-happy}"

# Read one line from stdin; exit on EOF.
# Do NOT echo to stderr -- the runner opens the port with :stderr_to_stdout,
# which would mix the echo into the JSON-RPC stream.
read_request() {
  IFS= read -r line || exit 0
}

# initialize
read_request
printf '%s\n' '{"id":1,"result":{}}'

# initialized (notification, no response)
read_request

# thread/start
read_request
printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-test"}}}'

if [[ "$mode" == "hang" ]]; then
  sleep 60
  exit 0
fi

turn_id=100
turns_emitted=0
while true; do
  IFS= read -r line || exit 0

  printf '{"id":%d,"result":{"turn":{"id":"turn-%d"}}}\n' "$turn_id" "$turn_id"

  case "$mode" in
    tool)
      printf '%s\n' '{"method":"item/tool/call","id":777,"params":{"tool":"linear_graphql","arguments":{}}}'
      IFS= read -r _tool_reply
      printf '%s\n' '{"method":"item/agentMessage/delta","params":{"text":"working"}}'
      printf '%s\n' '{"method":"turn/completed","usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}'
      ;;
    approval)
      printf '%s\n' '{"method":"item/commandExecution/requestApproval","id":555}'
      IFS= read -r _approval_reply
      printf '%s\n' '{"method":"turn/completed"}'
      ;;
    fail)
      printf '%s\n' '{"method":"turn/failed","params":{"reason":"boom"}}'
      ;;
    multi|happy|*)
      printf '%s\n' '{"method":"item/agentMessage/delta","params":{"text":"hello"}}'
      printf '%s\n' '{"method":"turn/completed","usage":{"total_tokens":42}}'
      ;;
  esac

  turn_id=$((turn_id + 1))
  turns_emitted=$((turns_emitted + 1))
done
