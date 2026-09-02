#!/usr/bin/env bash
# check_toolchain.sh -- fail loudly when the active Elixir/Erlang is not the one
# mise.toml declares.
#
# Why this exists: running a different Elixir than $MIX_HOME was populated for
# does not produce a version complaint. It produces this, from deep inside Hex,
# on any `mix deps.get`:
#
#     ** (UndefinedFunctionError) function Enum.__in__/2 is undefined or private
#
# which reads as a corrupt dependency rather than a toolchain mismatch, and
# costs an hour if you take it at face value. The usual cause is a
# Homebrew-first PATH with $MIX_HOME pointing at a mise install.
#
#   scripts/check_toolchain.sh          # report, exit 1 on mismatch
#   scripts/check_toolchain.sh --quiet  # exit code only

set -euo pipefail

# shellcheck disable=SC1007  # CDPATH= is an intentional env prefix for a safe cd
REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MISE_TOML="$REPO_ROOT/mise.toml"
QUIET=false
[[ ${1:-} == "--quiet" ]] && QUIET=true

say() { [[ "$QUIET" == true ]] || printf '%s\n' "$1"; }

if [[ ! -f "$MISE_TOML" ]]; then
  say "check_toolchain: no mise.toml at $MISE_TOML; nothing to check"
  exit 0
fi

# Reads one `<tool> = "<version>"` entry out of the `[tools]` table. Scoped to
# that table so a version living under some other table is not mistaken for the
# pin, and it takes the first quoted value on the line, so a trailing comment is
# not part of the version.
pinned() {
  awk -v tool="$1" '
    /^[[:space:]]*\[/ { in_tools = ($0 ~ /^[[:space:]]*\[tools\][[:space:]]*$/); next }
    in_tools && $1 == tool && match($0, /"[^"]*"/) {
      print substr($0, RSTART + 1, RLENGTH - 2)
      exit
    }
  ' "$MISE_TOML"
}

# elixir = "1.20.2-otp-29" -> "1.20.2"; erlang = "29.0.3" -> "29"
want_elixir=$(pinned elixir | sed 's/-otp-.*//')
want_otp=$(pinned erlang | cut -d. -f1)

if ! command -v elixir >/dev/null 2>&1; then
  say "check_toolchain: no elixir on PATH"
  exit 1
fi

# "Elixir 1.20.2 (compiled with Erlang/OTP 29)"
version_line=$(elixir --version 2>/dev/null | grep '^Elixir ' || true)
have_elixir=$(printf '%s' "$version_line" | awk '{print $2}')
have_otp=$(printf '%s' "$version_line" | sed -n 's/.*Erlang\/OTP \([0-9]*\).*/\1/p')

# Spelled out as `if` rather than `[[ … ]] && ok=false`: under `set -e` the
# latter only survives a false test by way of the AND-list exemption, which is
# too subtle to rest a build gate on.
ok=true

if [[ -n "$want_elixir" && "$have_elixir" != "$want_elixir" ]]; then
  ok=false
fi

if [[ -n "$want_otp" && "$have_otp" != "$want_otp" ]]; then
  ok=false
fi

if [[ "$ok" == true ]]; then
  say "check_toolchain: ok -- elixir $have_elixir, OTP $have_otp"
  exit 0
fi

say "check_toolchain: TOOLCHAIN MISMATCH"
say "  mise.toml wants      : elixir ${want_elixir:-?}, OTP ${want_otp:-?}"
say "  on PATH              : elixir ${have_elixir:-?}, OTP ${have_otp:-?} ($(command -v elixir))"
say "  MIX_HOME             : ${MIX_HOME:-<unset>}"
say ""
say "  Expect 'Enum.__in__/2 is undefined' from mix deps.get in this state."
say "  Fix: activate mise for this shell, or put its bins first:"
say ""
say "    eval \"\$(mise activate bash)\"   # or zsh"
say ""
say "  One-shot, without touching the shell:"
say ""
say "    PATH=\"\$HOME/.local/share/mise/installs/elixir/<ver>/bin:\\"
say "          \$HOME/.local/share/mise/installs/erlang/<ver>/bin:\$PATH\" mix deps.get"
exit 1
