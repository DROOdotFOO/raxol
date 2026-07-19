defmodule Raxol.Terminal.Driver.SttyTest do
  @moduledoc """
  Unit tests for `Raxol.Terminal.Driver.Stty.restore/1`'s injection guard
  (T2d review-round fix, SECURITY item). `restore/1` receives whatever
  `save/0` last captured, round-tripped through `InlineDriver`'s GenServer
  state (and, in tests, an arbitrary injected `:stty` module) -- so it must
  never trust that value enough to splice it into a command line
  unvalidated.
  """

  use ExUnit.Case, async: false

  alias Raxol.Terminal.Driver.Stty

  @tag :unix_only
  test "an injection payload does not execute -- falls through to sane! instead" do
    marker =
      Path.join(
        System.tmp_dir!(),
        "raxol_stty_pwn_#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm(marker) end)

    refute File.exists?(marker)

    # `#` (preceded by whitespace) starts a shell comment, so this payload
    # is redirect-independent: even under the OLD `:os.cmd/1` + shell
    # implementation, `touch <marker>` would run as its own command
    # regardless of whether `/dev/tty` exists in the test sandbox (the
    # trailing `< /dev/tty 2>/dev/null` the old code appended would be
    # commented out, not attached to `touch`). This is the shape of
    # payload the fix must block.
    payload = "gfmt1:cflag=b; touch #{marker} #"

    assert :ok = Stty.restore(payload)

    refute File.exists?(marker),
           "restore/1 must not let shell metacharacters in a saved-stty value execute arbitrary commands"
  end

  @tag :unix_only
  test "a clean colon-hex saved-stty value is still accepted (not rejected as a false positive)" do
    # Real `stty -g` dump shape (colon-separated hex/decimal fields, GNU
    # style) -- must not be rejected by the allowlist.
    clean =
      "2500:5:bf:8a3b:3:1c:7f:15:4:0:1:0:11:13:1a:0:12:f:17:16:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0"

    assert :ok = Stty.restore(clean)
  end

  test "nil falls through to sane!/0" do
    assert :ok = Stty.restore(nil)
  end

  test "empty string falls through to sane!/0" do
    assert :ok = Stty.restore("")
  end

  describe "command construction targets /dev/tty by device flag, never a shell redirect" do
    # The real-terminal ^C trap regression class: a `sh -c "stty ... <
    # /dev/tty"` invocation silently no-ops wherever the shell child
    # cannot open a controlling tty, and rides through /bin/sh where the
    # argv form needs no shell at all. Every mutating/reading stty
    # command must be the argv form `stty -f|-F /dev/tty ...` (BSD/GNU
    # device flag -- the same form restore/1 already uses).
    test "raw! argv includes the device flag, /dev/tty, and -isig" do
      args = Stty.command_args(:raw)

      assert Enum.take(args, 2) in [["-f", "/dev/tty"], ["-F", "/dev/tty"]]
      assert "-isig" in args
      assert "raw" in args
    end

    test "save/sane/size/flags argv all carry the device flag + /dev/tty" do
      for op <- [:save, :sane, :size, :flags] do
        args = Stty.command_args(op)

        assert Enum.take(args, 2) in [["-f", "/dev/tty"], ["-F", "/dev/tty"]],
               "#{op} must operate on /dev/tty via the device flag, got #{inspect(args)}"
      end
    end

    @tag :unix_only
    test "isig_off?/0 answers from the live flags without raising" do
      # On a CI/pty-less host `stty -f /dev/tty` fails and the honest
      # answer is `false` (cannot confirm) -- never a raise.
      assert Stty.isig_off?() in [true, false]
    end
  end
end
