defmodule Raxol.Harness.Surface.GoldenSnapshotTest do
  @moduledoc """
  Byte-golden snapshot tests for the harness degradation ladder: each
  fixed fixture session x render mode pair in
  `Raxol.Harness.Surface.Golden.fixtures()/modes()` is rendered end-to-end
  through the assembled `Raxol.Harness.Surface` and compared byte-for-byte
  against a checked-in golden file
  (`test/fixtures/harness/goldens/<fixture>.<mode>.golden`).

  Complements, rather than duplicates, `test/harness/t13a_surface_test.exs`
  (which asserts SEMANTIC invariants -- footer confinement, no-full-clear,
  seal-once, unicode survival -- via the O1/O2 oracles and plain-text
  projections) and `test/harness/golden_diff_test.exs` (which unit-tests
  the diff formatter in isolation). This suite is the byte-exact
  regression net one level below both: any change to the emitted bytes at
  all -- intentional or not -- fails here first, with a bounded, readable
  diff (never a raw binary dump) pointing at the first divergent byte.

  Run `mix raxol.harness.goldens.bless` to (re)generate the golden files
  after an intentional rendering change, and `mix raxol.harness.goldens.bless
  --check` to verify without writing (the CI-facing half).
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Surface.{Golden, GoldenDiff}
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Test.CrossTerminal.SequenceScanner

  # ---------------------------------------------------------------------
  # (a) byte-golden + (b) determinism, one test pair per fixture x mode
  # ---------------------------------------------------------------------

  for fixture <- Golden.fixtures(), mode <- Golden.modes() do
    @fixture fixture
    @mode mode

    test "#{fixture} x #{mode}: byte-for-byte match against the checked-in golden" do
      rendered = Golden.render(@fixture, @mode)
      path = Golden.golden_path(@fixture, @mode)

      golden =
        case File.read(path) do
          {:ok, bytes} ->
            bytes

          {:error, _reason} ->
            flunk(
              "golden missing at #{path} -- run `mix raxol.harness.goldens.bless`"
            )
        end

      case GoldenDiff.compare(golden, rendered) do
        :ok ->
          :ok

        {:diverged, _offset, report} ->
          flunk(
            "#{@fixture} x #{@mode} diverged from its checked-in golden -- " <>
              "if this is intentional, run `mix raxol.harness.goldens.bless` " <>
              "and review the diff before re-committing:\n\n#{report}"
          )
      end
    end

    test "#{fixture} x #{mode}: rendering twice in one run is byte-identical (determinism tripwire)" do
      first = Golden.render(@fixture, @mode)
      second = Golden.render(@fixture, @mode)

      assert first == second,
             "#{@fixture} x #{@mode} rendered different bytes across two calls " <>
               "in the SAME run -- some hidden state (map iteration order, " <>
               "process dictionary, unseeded randomness) is leaking into the " <>
               "byte stream; see Golden's moduledoc determinism audit"
    end
  end

  # ---------------------------------------------------------------------
  # (c) semantic guards on the CHECKED-IN golden bytes (must survive
  #     re-blessing -- these read the golden file, never a fresh render)
  # ---------------------------------------------------------------------

  describe "semantic guards on checked-in goldens" do
    test "flat mode goldens contain zero ESC bytes and zero escape-sequence tokens" do
      for fixture <- Golden.fixtures() do
        golden = read_golden!(fixture, :flat)

        refute golden =~ <<0x1B>>,
               "#{fixture} x flat golden contains a raw ESC byte"

        assert Enum.all?(SequenceScanner.scan(golden), &match?({:text, _}, &1)),
               "#{fixture} x flat golden contains a non-text (escape-sequence) token"
      end
    end

    test "inline_log and tmux_conservative goldens never emit a full-screen clear" do
      for fixture <- Golden.fixtures(),
          mode <- [:inline_log, :tmux_conservative] do
        golden = read_golden!(fixture, mode)

        refute golden =~ "\e[2J",
               "#{fixture} x #{mode} golden contains \\e[2J (full clear)"

        refute golden =~ "\e[3J",
               "#{fixture} x #{mode} golden contains \\e[3J (full clear + scrollback)"

        refute SealOracle.emits_full_clear?(golden),
               "#{fixture} x #{mode} golden emits a full clear per SealOracle"
      end
    end
  end

  # ---------------------------------------------------------------------
  # (d) guard falsifiability: prove each guard above CAN actually fail,
  #     independent of what today's golden content happens to contain
  # ---------------------------------------------------------------------

  describe "guard falsifiability" do
    test "SealOracle.emits_full_clear?/1 detects an injected \\e[2J" do
      assert SealOracle.emits_full_clear?("x\e[2Jy")
      assert SealOracle.emits_full_clear?("x\e[3Jy")
      refute SealOracle.emits_full_clear?("no clears here")
    end

    test "the flat zero-escape guard fails on a string containing an ESC byte" do
      corrupted = "plain text\e[31mred text"

      refute Enum.all?(
               SequenceScanner.scan(corrupted),
               &match?({:text, _}, &1)
             ),
             "a corrupted flat stream with an embedded ESC must fail the " <>
               "all-tokens-are-text guard"

      assert corrupted =~ <<0x1B>>
    end
  end

  # ---------------------------------------------------------------------
  # (e) drift tripwire: the in-suite mirror of `mix raxol.harness.goldens.bless
  #     --check` (same spirit as test/harness/tf_fixture_test.exs's own
  #     ".blocks.json is current" drift check)
  # ---------------------------------------------------------------------

  describe "drift tripwire" do
    test "the full fixtures x modes matrix is current against its checked-in goldens" do
      assert {:ok, _results} = Golden.run(check: true)
    end
  end

  defp read_golden!(fixture, mode) do
    path = Golden.golden_path(fixture, mode)

    case File.read(path) do
      {:ok, bytes} ->
        bytes

      {:error, _reason} ->
        flunk(
          "golden missing at #{path} -- run `mix raxol.harness.goldens.bless`"
        )
    end
  end
end
