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

  # These tests really do invoke `stty`, and it now targets a resolved
  # device instead of failing to open `/dev/tty` -- so without this it
  # would apply a foreign saved-settings dump to whichever terminal is
  # running the suite. Point it somewhere that is not a tty: the argv is
  # still built and executed (which is what the injection test proves),
  # the command just cannot touch a real session.
  setup do
    Application.put_env(:raxol_terminal, :stty_device, "/dev/null")
    on_exit(fn -> Application.delete_env(:raxol_terminal, :stty_device) end)
    :ok
  end

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

  describe "command construction targets the tty by device flag, never a shell redirect" do
    # The real-terminal ^C trap regression class: a `sh -c "stty ... <
    # /dev/tty"` invocation silently no-ops wherever the shell child
    # cannot open a controlling tty, and rides through /bin/sh where the
    # argv form needs no shell at all. Every mutating/reading stty
    # command must be the argv form `stty -f|-F DEVICE ...` (BSD/GNU
    # device flag -- the same form restore/1 already uses).
    test "raw! argv includes the device flag, the device, and -isig" do
      args = Stty.command_args(:raw)

      assert [flag, device | _rest] = args
      assert flag in ["-f", "-F"]
      assert device == Stty.tty_device()
      assert "-isig" in args
      assert "raw" in args
    end

    test "save/sane/size/flags argv all carry the device flag + the device" do
      for op <- [:save, :sane, :size, :flags] do
        args = Stty.command_args(op)

        assert [flag, device | _rest] = args
        assert flag in ["-f", "-F"], "#{op} must use the device flag, got #{inspect(args)}"

        assert device == Stty.tty_device(),
               "#{op} must operate on the resolved device, got #{inspect(args)}"
      end
    end

    # The device is never the literal `/dev/tty` when one can be
    # resolved: a `System.cmd`-spawned stty is in a fresh session with no
    # controlling terminal, so `/dev/tty` fails ENXIO for it and every
    # operation in this module silently no-ops. That is the bug this
    # resolution exists to close, so pin that it produces a real path
    # wherever the test host has a tty at all.
    @tag :unix_only
    test "tty_device/0 resolves a concrete device path, or falls back honestly" do
      Application.delete_env(:raxol_terminal, :stty_device)

      device = Stty.tty_device()

      assert String.starts_with?(device, "/dev/")
      assert device == Stty.tty_device(), "must be stable across calls (cached)"
    end

    test "the configured device overrides resolution" do
      Application.put_env(:raxol_terminal, :stty_device, "/dev/null")

      assert Stty.tty_device() == "/dev/null"
      assert Enum.take(Stty.command_args(:raw), 2) |> List.last() == "/dev/null"
    end

    @tag :unix_only
    test "isig_off?/0 answers from the live flags without raising" do
      # On a CI/pty-less host `stty -f /dev/tty` fails and the honest
      # answer is `false` (cannot confirm) -- never a raise.
      assert Stty.isig_off?() in [true, false]
    end
  end
end
