defmodule Raxol.Terminal.Capabilities.CapabilitySliceAnchorTest do
  @moduledoc """
  T1 fail-first anchor (harness-ui-roadmap §4, suite 04: "env-sniff vs
  DECRQM (hardcoded false)").

  Mode-2026 (synchronized output) support must be decided by parsing a
  DECRQM reply (`CSI ? 2026 ; Ps $ y`) off the wire -- never by
  `$TERM_PROGRAM` sniffing. Today `advanced_features.ex` sniffs
  `$TERM_PROGRAM` and its `query_synchronized_output_support/0` is
  hardcoded `false`; no DECRQM reply parser exists anywhere. These tests
  are red on master and go green with the T1 capability slice.
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Capabilities.Probe

  test "2026 detection comes from a DECRQM reply, not env sniffing" do
    # env deliberately says NOTHING that an env-sniffer would recognize
    # as a 2026-capable terminal:
    env = %{"TERM" => "xterm-256color"}

    probe = Probe.new(env, budget_ms: 100)
    {probe, actions} = Probe.step(probe, :start)

    # the probe must actually ASK via DECRQM
    assert Enum.any?(actions, fn
             {:write, iodata} ->
               IO.iodata_to_binary(iodata) =~ "\e[?2026$p"

             _ ->
               false
           end)

    # the terminal answers DECRQM 2026 = set (1), then the DA1 sentinel
    {probe, _actions} = Probe.step(probe, {:input, "\e[?2026;1$y\e[?62;4c"})
    {probe, _actions} = Probe.step(probe, {:clock, 10})

    assert {:done, caps} = Probe.result(probe)
    assert caps.sync_output == true
    # provenance: the cap was set by the DECRQM reply, not the env seed
    assert caps.source.sync_output == :decrqm
  end

  test "env sniffing alone can never claim 2026 support" do
    # $TERM_PROGRAM screams kitty (the exact string the current
    # env-sniff trusts), but the wire stays SILENT -> unsupported.
    env = %{"TERM" => "xterm-kitty", "TERM_PROGRAM" => "kitty"}

    probe = Probe.new(env, budget_ms: 100)
    {probe, _actions} = Probe.step(probe, :start)
    {probe, _actions} = Probe.step(probe, {:clock, 101})

    assert {:done, caps} = Probe.result(probe)
    assert caps.sync_output == false
    assert caps.source.sync_output != :env
  end
end
