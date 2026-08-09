#!/usr/bin/env bash
# Work around a harbor bug that kills an ACP run before it prompts.
#
# With a model requested (`harbor run -m ...`), harbor's ACP runner calls
# `conn.set_session_model(...)`, but installs `agent-client-protocol` UNPINNED.
# A released SDK without that method raises AttributeError, and the runner
# rescues only RequestError -- so the trial dies during setup, reporting
# NonZeroAgentExitCodeError with nothing useful in the log.
#
# Guard the call on the attribute existing. Skipping the set_model attempt is
# harmless for raxol: the model already arrives through
# HARBOR_ACP_REQUESTED_MODEL, which `Raxol.Agent.ClientProtocol.Serve` reads.
#
# Implementing `session/set_model` agent-side would NOT help -- the crash is in
# harbor's own process before anything reaches the wire.
#
# Idempotent. Run once per harbor venv:
#   packages/raxol_cli/tbench/harbor-patch.sh /path/to/venv
set -euo pipefail

venv="${1:-}"
if [[ -z "$venv" ]]; then
  printf 'usage: %s <path-to-harbor-venv>\n' "$0" >&2
  exit 64
fi

runner="$(find "$venv" -path '*/harbor/agents/installed/acp_runner.py' -print -quit)"
if [[ -z "$runner" ]]; then
  printf 'no harbor acp_runner.py under %s\n' "$venv" >&2
  exit 1
fi

before='if requested_model:'
after='if requested_model and hasattr(conn, "set_session_model"):'

if grep -qF "$after" "$runner"; then
  printf 'already patched: %s\n' "$runner"
  exit 0
fi

if ! grep -qF "            $before" "$runner"; then
  printf 'guard site not found in %s -- harbor may have fixed or moved it\n' "$runner" >&2
  exit 1
fi

python3 - "$runner" "$before" "$after" <<'PY'
import sys, pathlib
path, before, after = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
s = p.read_text()
old = "            " + before
assert s.count(old) == 1, f"expected exactly one guard site, found {s.count(old)}"
p.write_text(s.replace(old, "            " + after))
PY

printf 'patched: %s\n' "$runner"
