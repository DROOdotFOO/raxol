defmodule Raxol.Terminal.Capabilities.CapabilitySliceProbeClockTest do
  @moduledoc """
  Probe reducer timing suite -- the fake-clock pattern (04 design §3).
  Time is an injected event; there is NO `Process.sleep` anywhere in this
  file. Covers CAP-N-01, CAP-P-03, the extend-once rule, the SSH-widened
  deadline, CAP-N-02/03, CAP-P-12, CAP-P-14.
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Capabilities.Probe

  describe "CAP-N-01: silence" do
    test "no reply -> conservative default within one budget, no waiting" do
      p = Probe.new(%{"TERM" => "dumb"}, budget_ms: 100)
      {p, [{:write, _query}]} = Probe.step(p, :start)

      # advance the fake clock straight past the deadline; ZERO input
      {p, actions} = Probe.step(p, {:clock, 101})

      assert {:done, caps} = Probe.result(p)
      assert caps.sync_output == false
      assert caps.tier == :core_minus
      refute Enum.any?(actions, &match?({:extend_deadline, _}, &1))
    end

    test "clock before the deadline stays pending" do
      p = Probe.new(%{}, budget_ms: 100)
      {p, _} = Probe.step(p, :start)
      {p, []} = Probe.step(p, {:clock, 99})
      assert Probe.result(p) == :pending
    end
  end

  describe "CAP-P-03: missing reply before the sentinel" do
    test "unanswered DECRQM is unsupported the moment DA1 drains" do
      p = Probe.new(%{}, budget_ms: 100)
      {p, _} = Probe.step(p, :start)

      # OSC 11 answered, DECRQM 2026 NOT, then the sentinel
      {p, actions} =
        Probe.step(p, {:input, "\e]11;rgb:1111/1111/1111\a\e[?62;c"})

      # sentinel arrived in the same chunk: no deadline extension
      refute Enum.any?(actions, &match?({:extend_deadline, _}, &1))

      # drain window closes on the next clock tick -- no timeout burned
      {p, _} = Probe.step(p, {:clock, 10})

      assert {:done, caps} = Probe.result(p)
      assert caps.sync_output == false
      assert caps.source.sync_output == :default
    end
  end

  describe "extend-once rule (F0 §7 step 3)" do
    test "first byte without sentinel extends the deadline exactly once" do
      p = Probe.new(%{}, budget_ms: 100, extend_ms: 100)
      {p, _} = Probe.step(p, :start)

      {p, actions} = Probe.step(p, {:input, "\e[?2026;1"})

      assert [{:extend_deadline, 100}] =
               Enum.filter(actions, &match?({:extend_deadline, _}, &1))

      # a second partial chunk must NOT extend again
      {p, actions2} = Probe.step(p, {:input, "$"})
      refute Enum.any?(actions2, &match?({:extend_deadline, _}, &1))

      # original deadline passed -- still pending (extension applies)
      {p, []} = Probe.step(p, {:clock, 150})
      assert Probe.result(p) == :pending

      # extended deadline passed -- done
      {p, _} = Probe.step(p, {:clock, 201})
      assert {:done, caps} = Probe.result(p)
      # the fragment never completed: unsupported, drained
      assert caps.sync_output == false
    end
  end

  describe "SSH-widened deadline" do
    test "same clock tick: local probe is done, SSH probe still pending" do
      local = Probe.new(%{"TERM" => "xterm-256color"})
      ssh = Probe.new(%{"TERM" => "xterm-256color", "SSH_TTY" => "/dev/tty1"})

      {local, _} = Probe.step(local, :start)
      {ssh, _} = Probe.step(ssh, :start)

      {local, _} = Probe.step(local, {:clock, 500})
      {ssh, []} = Probe.step(ssh, {:clock, 500})

      assert {:done, _} = Probe.result(local)
      assert Probe.result(ssh) == :pending

      {ssh, _} = Probe.step(ssh, {:clock, 1001})
      assert {:done, _} = Probe.result(ssh)
    end
  end

  describe "CAP-N-02: reordered reply inside the drain window" do
    test "OSC 11 arriving after DA1 (later chunk, same window) is parsed" do
      p = Probe.new(%{}, budget_ms: 100)
      {p, _} = Probe.step(p, :start)
      {p, _} = Probe.step(p, {:input, "\e[?2026;1$y\e[?62;c"})
      # the window is still open until the next clock tick
      {p, _} = Probe.step(p, {:input, "\e]11;rgb:0000/0000/0000\a"})
      {p, _} = Probe.step(p, {:clock, 10})

      assert {:done, caps} = Probe.result(p)
      assert caps.sync_output == true
      assert p.scanner.osc11 == {:ok, {0, 0, 0}}
    end
  end

  describe "CAP-N-03: late reply after :done" do
    test "classification immutable; late reply drained; keys still flow" do
      p = Probe.new(%{}, budget_ms: 100)
      {p, _} = Probe.step(p, :start)
      {p, _} = Probe.step(p, {:input, "\e[?62;c"})
      {p, [{:done, caps}]} = Probe.step(p, {:clock, 10})

      # a late OSC 11 reply: drained, never leaked, never reclassified
      {p, actions} = Probe.step(p, {:input, "\e]11;rgb:ffff/ffff/ffff\a"})
      assert actions == []
      assert {:done, ^caps} = Probe.result(p)

      # real keystrokes after :done still pass through
      {p, [{:leak_free, "x"}]} = Probe.step(p, {:input, "x"})
      assert {:done, ^caps} = Probe.result(p)
    end
  end

  describe "CAP-P-12: non-TTY path" do
    test "stdout not a tty -> Core-minus, ZERO queries emitted" do
      p = Probe.new(%{"TERM" => "xterm-256color"}, tty?: false)
      {p, actions} = Probe.step(p, :start)

      refute Enum.any?(actions, &match?({:write, _}, &1))
      refute Enum.any?(actions, &match?({:passthrough, _}, &1))

      assert {:done, caps} = Probe.result(p)
      assert caps.tier == :core_minus
      assert caps.sync_output == false
    end
  end

  describe "CAP-P-14: tmux passthrough re-issue" do
    test "passthrough wrap emitted, payload bounded, outer identity parsed" do
      env = %{"TMUX" => "/tmp/tmux-501/default,1,0", "TERM" => "screen"}
      p = Probe.new(env, budget_ms: 100, tmux_passthrough?: true)

      {p, actions} = Probe.step(p, :start)

      assert [{:passthrough, wrapped}] =
               Enum.filter(actions, &match?({:passthrough, _}, &1))

      wrapped = IO.iodata_to_binary(wrapped)
      assert String.starts_with?(wrapped, "\ePtmux;")
      assert String.ends_with?(wrapped, "\e\\")

      # inner payload: ESC-doubled, and well under the ~60 char truncation
      "\ePtmux;" <> inner_st = wrapped
      inner = String.replace_suffix(inner_st, "\e\\", "")
      payload = String.replace(inner, "\e\e", "\e")
      assert String.length(payload) < 60

      # outer terminal's forwarded XTVERSION still parses
      {p, _} = Probe.step(p, {:input, "\eP>|kitty(0.32.2)\e\\\e[?62;c"})
      {p, _} = Probe.step(p, {:clock, 10})

      assert {:done, caps} = Probe.result(p)
      assert caps.identity == {"kitty", "0.32.2"}
      # ... but the conservative clamp still applies inside tmux
      assert caps.multiplexer == :tmux
      assert caps.sync_output == false
    end

    test "no passthrough action without opt-in" do
      env = %{"TMUX" => "/tmp/tmux-501/default,1,0"}
      p = Probe.new(env, budget_ms: 100)
      {_p, actions} = Probe.step(p, :start)
      refute Enum.any?(actions, &match?({:passthrough, _}, &1))
    end
  end

  describe "reducer hygiene" do
    test "empty input chunk is a no-op (no scan, no extension)" do
      p = Probe.new(%{}, budget_ms: 100)
      {p, _} = Probe.step(p, :start)
      {p, []} = Probe.step(p, {:input, ""})
      {_p, actions} = Probe.step(p, {:input, "\e[?62;c"})
      # the sentinel chunk is genuinely the first byte -- and since the
      # sentinel arrived with it, still no extension
      refute Enum.any?(actions, &match?({:extend_deadline, _}, &1))
    end

    test "stray :start after :start is a no-op" do
      p = Probe.new(%{}, budget_ms: 100)
      {p, _} = Probe.step(p, :start)
      {p, []} = Probe.step(p, :start)
      assert Probe.result(p) == :pending
    end
  end
end
