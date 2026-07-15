defmodule Raxol.Terminal.Capabilities.CapabilitySliceCacheTest do
  @moduledoc """
  CAP-P-13: `:persistent_term` cache round-trip + session immutability,
  and the driver-facing wiring: `BackgroundQuery` emits the DECRQM 2026
  query in its batched write (DA1 sentinel LAST), routes replies through
  the ReplyScanner, and `Capabilities.sync_output?/0` -- the ONE public
  emit-gate -- answers from the wire.

  `async: false`: `:persistent_term` is process-global.
  """
  use ExUnit.Case, async: false

  alias Raxol.Terminal.Capabilities
  alias Raxol.Terminal.Driver.BackgroundQuery

  setup do
    Capabilities.reset_cache()
    on_exit(fn -> Capabilities.reset_cache() end)
    :ok
  end

  describe "CAP-P-13: cache round-trip and immutability" do
    test "classify once; second read identical; re-cache no-ops" do
      caps = %Capabilities{tier: :modern, sync_output: true}

      assert Capabilities.cached() == :error
      assert Capabilities.cache(caps) == :ok
      assert Capabilities.cached() == {:ok, caps}

      # session-immutable: a second cache write is a no-op
      other = %Capabilities{tier: :core, sync_output: false}
      assert Capabilities.cache(other) == :ok
      assert Capabilities.cached() == {:ok, caps}
    end

    test "sync_output?/0 answers from the cached record" do
      refute Capabilities.sync_output?()

      Capabilities.cache(%Capabilities{sync_output: true})
      assert Capabilities.sync_output?()
    end

    test "sync_output?/0 falls back to noted DECRQM replies" do
      refute Capabilities.sync_output?()
      Capabilities.note_mode_reply(2026, 2)
      assert Capabilities.sync_output?()
    end

    test "a negative DECRQM reply never reads as support" do
      Capabilities.note_mode_reply(2026, 0)
      refute Capabilities.sync_output?()
    end
  end

  describe "batched write (T1 extension of the existing driver query)" do
    test "query includes DECRQM 2026 with the DA1 sentinel LAST" do
      query = BackgroundQuery.query_sequence()

      assert query =~ "\e]11;?\a"
      assert query =~ "\e[?2026$p"
      assert String.ends_with?(query, "\e[c")
    end
  end

  describe "reply routing through the ReplyScanner" do
    test "a DECRQM 2026 reply in the driver stream feeds the gate" do
      refute Capabilities.sync_output?()

      {result, cleaned} = BackgroundQuery.scan("\e[?2026;1$y")

      # the reply is stripped from the stream (never a keystroke) ...
      assert cleaned == ""
      # ... the OSC 11 outcome is still pending (no color, no sentinel) ...
      assert result == :pending
      # ... and the 2026 gate now answers true, from the wire
      assert Capabilities.mode_replies() == %{2026 => 1}
      assert Capabilities.sync_output?()
    end

    test "full driver read: color + DECRQM + sentinel + keystrokes" do
      {result, cleaned} =
        BackgroundQuery.scan("a\e]11;rgb:2b2b/2b2b/2b2b\a\e[?2026;2$y\e[?62;cb")

      assert result == {:ok, {43, 43, 43}}
      assert cleaned == "ab"
      assert Capabilities.sync_output?()
    end

    test "sentinel without a DECRQM reply leaves the gate closed" do
      {result, cleaned} = BackgroundQuery.scan("\e[?1;2c")
      assert result == :unsupported
      assert cleaned == ""
      refute Capabilities.sync_output?()
    end
  end
end
