defmodule Raxol.Terminal.Driver.CapabilitiesProbeIntegrationTest do
  @moduledoc """
  Driver-level integration for the F0 capabilities bridge
  (`Raxol.Terminal.Driver`'s `start_capabilities_probe/1`,
  `route_capabilities_input/2`, `step_capabilities_clock/1`): the batched
  Probe query, reply routing through the live GenServer's ordinary
  raw-input path, residual discipline (interleaved keystrokes survive in
  order), the compat event pair, and the silence/defaults guard.

  `init_manager/1`'s real TTY branch -- where `start_capabilities_probe/1`
  is actually invoked -- is unreachable from ExUnit: `Env.test?/0`
  short-circuits it before that branch runs, same as the pre-existing
  `driver_init_order_test.exs`. So these tests start the driver normally
  (test-mode init, no real probe write), then inject a live `%Probe{}` --
  already stepped past `:start`, exactly what the TTY branch would have
  produced -- via `:sys.replace_state/2`, and drive it through the SAME
  message path a real terminal's replies arrive on: `{:raw_input, data}`
  (the trace/port path funnels here after `InputBuffer` assembly) and the
  `:capabilities_probe_clock` deadline tick.
  """
  use ExUnit.Case, async: false

  alias Raxol.Core.Events.Event
  alias Raxol.Terminal.Capabilities
  alias Raxol.Terminal.Capabilities.Probe
  alias Raxol.Terminal.Driver
  alias Raxol.Terminal.Driver.BackgroundQuery

  setup do
    Capabilities.reset_cache()
    on_exit(fn -> Capabilities.reset_cache() end)
    :ok
  end

  # Starts a driver in test-mode (Env.test?/0 true -- no real probe write,
  # no real tty setup) and injects a live Probe already past `:start` (the
  # state the unreachable TTY branch would have produced) via
  # :sys.replace_state/2.
  defp start_driver_with_probe(probe_opts \\ []) do
    {:ok, driver_pid} = Driver.start_link(self())
    assert_receive {:driver_ready, ^driver_pid}
    assert_receive {:"$gen_cast", {:dispatch, %Event{type: :resize}}}

    opts = Keyword.put_new(probe_opts, :now_ms, System.monotonic_time(:millisecond))
    probe = Probe.new(System.get_env(), opts)
    {probe, _actions} = Probe.step(probe, :start)

    :sys.replace_state(driver_pid, fn state ->
      %{state | capabilities_probe: probe}
    end)

    driver_pid
  end

  test "the probe's batched query carries OSC 11, OSC 10, and ends with the DA1 sentinel" do
    query = Probe.query_sequence()

    assert query =~ "\e]11;?\a"
    assert query =~ "\e]10;?\a"
    assert String.ends_with?(query, "\e[c")
  end

  describe "reply routing through the live driver" do
    test "scripted replies interleaved with keystrokes: capabilities cached, compat events fired, keystrokes intact and in order" do
      driver_pid = start_driver_with_probe()

      # A real read(2) rarely delivers the whole batched reply in one
      # chunk -- split it across two raw_input messages, each carrying a
      # keystroke alongside a reply, exactly as bytes would interleave on
      # the wire.
      send(driver_pid, {:raw_input, "a\e]11;rgb:1010/1010/1010\a"})
      send(driver_pid, {:raw_input, "b\e]10;rgb:e8e8/e8e8/e8e8\ac\e[?62;c"})

      # DA1 sentinel just arrived -> phase :draining. Close the drain
      # window (the ONE clock tick the real deadline timer would
      # eventually deliver) so classification finalizes.
      send(driver_pid, :capabilities_probe_clock)

      # Keystrokes survive, in order, none dropped, none duplicated, none
      # reordered relative to the replies they rode alongside.
      assert_receive {:"$gen_cast",
                       {:dispatch, %Event{type: :key, data: %{key: :char, char: "a"}}}}

      assert_receive {:"$gen_cast",
                       {:dispatch, %Event{type: :key, data: %{key: :char, char: "b"}}}}

      assert_receive {:"$gen_cast",
                       {:dispatch, %Event{type: :key, data: %{key: :char, char: "c"}}}}

      # Compat side effect #1: the old OSC 11 background event, preserved
      # verbatim for existing consumers.
      assert_receive {:"$gen_cast",
                       {:dispatch,
                        %Event{type: :terminal_background, data: %{color: {16, 16, 16}}}}}

      # New side effect: the full classified capabilities record.
      assert_receive {:"$gen_cast",
                       {:dispatch,
                        %Event{
                          type: :terminal_capabilities,
                          data: %{capabilities: %Capabilities{} = caps}
                        }}}

      assert caps.background == {16, 16, 16}
      assert caps.foreground == {232, 232, 232}
      assert caps.source.background == :osc11
      assert caps.source.foreground == :osc10

      # Capabilities.cache/1 ran: the session record is readable straight
      # off the cache (native-palette-riding's Capabilities.background/0
      # / foreground/0 readers, and main raxol's SalienceTheme, both read
      # through this).
      assert {:ok, cached} = Capabilities.cached()
      assert cached.background == {16, 16, 16}
      assert cached.foreground == {232, 232, 232}

      # Compat side effect #2: BackgroundQuery.store/1 (the old
      # persistent_term write) also ran. Prove it independently of the
      # Capabilities cache by clearing that cache and confirming
      # detected_background/0 still answers via its legacy fallback path.
      Capabilities.reset_cache()
      assert BackgroundQuery.detected_background() == {:ok, {16, 16, 16}}

      assert Process.alive?(driver_pid)
      GenServer.stop(driver_pid)
    end

    test "a keystroke arriving before any reply bytes still flows through immediately" do
      driver_pid = start_driver_with_probe()

      send(driver_pid, {:raw_input, "x"})

      assert_receive {:"$gen_cast",
                       {:dispatch, %Event{type: :key, data: %{key: :char, char: "x"}}}}

      GenServer.stop(driver_pid)
    end
  end

  describe "silence guard: terminals that answer only partially or not at all" do
    test "DA1-only reply (every other query silent): record cached with defaults, no crash" do
      driver_pid = start_driver_with_probe()

      send(driver_pid, {:raw_input, "\e[?62;c"})
      send(driver_pid, :capabilities_probe_clock)

      assert_receive {:"$gen_cast",
                       {:dispatch,
                        %Event{
                          type: :terminal_capabilities,
                          data: %{capabilities: %Capabilities{} = caps}
                        }}}

      assert caps.background == nil
      assert caps.foreground == nil
      assert caps.sync_output == false
      assert caps.source.background == :default

      refute_received {:"$gen_cast", {:dispatch, %Event{type: :terminal_background}}}

      assert Process.alive?(driver_pid)
      GenServer.stop(driver_pid)
    end

    test "total silence (not even DA1): the deadline timer alone finalizes to core_minus defaults, no crash" do
      # Backdate the probe's clock origin well into the past so the
      # driver's :capabilities_probe_clock handler -- which reads the
      # REAL wall clock, exactly as production does -- sees the deadline
      # as already elapsed without this test actually sleeping for the
      # local/SSH probe budget.
      backdated_now = System.monotonic_time(:millisecond) - 1_000_000
      driver_pid = start_driver_with_probe(now_ms: backdated_now)

      # No :raw_input at all -- only the clock tick a real deadline timer
      # would eventually deliver.
      send(driver_pid, :capabilities_probe_clock)

      assert_receive {:"$gen_cast",
                       {:dispatch,
                        %Event{
                          type: :terminal_capabilities,
                          data: %{capabilities: %Capabilities{} = caps}
                        }}}

      assert caps.tier == :core_minus
      assert caps.background == nil
      assert caps.foreground == nil
      assert caps.sync_output == false

      refute_received {:"$gen_cast", {:dispatch, %Event{type: :terminal_background}}}

      assert Process.alive?(driver_pid)
      GenServer.stop(driver_pid)
    end
  end

  describe "post-finalize input routing (capabilities_probe retirement)" do
    test "a lone ESC keystroke after finalize reaches input, not swallowed by a stale probe" do
      driver_pid = start_driver_with_probe()

      # Finalize via the DA1-only silence-guard path (mirrors the "silence
      # guard" tests above): sentinel arrives, clock tick finalizes.
      send(driver_pid, {:raw_input, "\e[?62;c"})
      send(driver_pid, :capabilities_probe_clock)

      assert_receive {:"$gen_cast",
                       {:dispatch,
                        %Event{
                          type: :terminal_capabilities,
                          data: %{capabilities: %Capabilities{}}
                        }}}

      # The probe is done; its job is over. A later, wholly unrelated lone
      # ESC keystroke (its own chunk, no more bytes behind it -- exactly
      # what a real read(2) delivers when a user taps Escape and pauses)
      # must reach the key parser instead of being parked as a Probe
      # "partial" and discarded on the next chunk.
      send(driver_pid, {:raw_input, "\e"})

      assert_receive {:"$gen_cast",
                       {:dispatch, %Event{type: :key, data: %{key: :escape}}}}

      assert Process.alive?(driver_pid)
      GenServer.stop(driver_pid)
    end
  end
end
