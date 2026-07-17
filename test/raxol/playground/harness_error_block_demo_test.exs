defmodule Raxol.Playground.HarnessErrorBlockDemoTest do
  @moduledoc """
  U1-d autotest: the `HarnessErrorBlockDemo` driven headlessly and via MCP.
  This demo doubles as the decision record for error-kind wiring (harness
  TEA migration sec 7): `:error` is a first-class `Block` kind rendered as
  an ALARM LINE (`✗ <message>`), decided by the tool-render unit. The test
  pins that ruling.

  §7 pins covered here:

    * real-message alarm -- `✗ <first line of the fault>`, read from the
      fault `reason` payload (the honest message, never `[error] (empty)`);
    * honest fallbacks -- `✗ error from <where>` when only an origin is
      carried, `✗ error (no message)` when the fault carries nothing;
    * expanded multi-line fault -- `[z]` peeks the full body under the
      alarm line;
    * the opaque forward-compat fallback for an unknown kind
      (`◆ [telemetry_probe] ...`, foldable);
    * separation law -- an error is NOT machinery: a blank row sets each
      fault off from its neighbours (no tight clustering with the tool);
    * alarm prominence -- the error header is non-dim, pinned at
      `Block.render/2`'s output map (the authoritative, backend-independent
      layer; see the tool demo test's note);
    * MCP derivation -- each block stamps its root :column and derives
      `<id>.toggle_fold` from the live tree.
  """
  use ExUnit.Case, async: false

  import Raxol.MCP.Test

  alias Raxol.Headless
  alias Raxol.Playground.Demos.HarnessErrorBlockDemo
  alias Raxol.UI.Components.Harness.Block

  @settle_ms 200

  setup do
    pid =
      case Process.whereis(Headless) do
        nil -> start_supervised!({Headless, [name: Headless]})
        existing -> existing
      end

    on_exit(fn ->
      if Process.alive?(pid) do
        for id <- GenServer.call(pid, :list_sessions) do
          try do
            GenServer.call(pid, {:stop_session, id}, 2_000)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    :ok
  end

  describe "alarm lines (the error-kind ruling)" do
    test "a real fault renders `✗ <first line>` -- the honest message, never (empty)" do
      id = start_headless()
      text = screenshot!(id)

      assert text =~ "✗ Connection refused by upstream (attempt 3)"
      refute text =~ "(empty)"
      refute text =~ "[error]"

      Headless.stop(id)
    end

    test "a message-less fault falls back honestly: `✗ error from <where>` and `✗ error (no message)`" do
      id = start_headless()
      text = screenshot!(id)

      assert text =~ "✗ error from tool_executor"
      assert text =~ "✗ error (no message)"

      Headless.stop(id)
    end

    test "an unknown kind renders the opaque forward-compat fallback, labeled + foldable" do
      id = start_headless()
      text = screenshot!(id)

      assert text =~ "◆ [telemetry_probe]"

      Headless.stop(id)
    end
  end

  describe "expand-to-full-fault via send_key" do
    test "[z] peeks the full multi-line fault body under the alarm line" do
      id = start_headless()

      # focus starts on err_full (folded): only the first line shows.
      refute screenshot!(id) =~ "retry budget exhausted"

      assert {:ok, %{blocks: %{err_full: %{fold: :folded}}}} =
               Headless.get_model(id)

      :ok = Headless.send_key(id, "z")
      Process.sleep(@settle_ms)

      assert {:ok, %{blocks: %{err_full: %{fold: :expanded}}}} =
               Headless.get_model(id)

      text = screenshot!(id)
      assert text =~ "✗ Connection refused by upstream (attempt 3)"
      assert text =~ "retry budget exhausted"

      Headless.stop(id)
    end
  end

  describe "separation law (error is signal, not machinery)" do
    test "a blank row sets the fault off from the tool neighbour above it" do
      id = start_headless()
      lines = screenshot!(id) |> String.split("\n")

      probe = Enum.find_index(lines, &String.contains?(&1, "probe target"))

      fault =
        Enum.find_index(lines, &String.contains?(&1, "Connection refused"))

      # Not adjacent: at least one blank row between the tool and the fault
      # (machinery clusters tight only with other machinery -- never a fault).
      assert fault > probe + 1

      assert Enum.any?(
               (probe + 1)..(fault - 1),
               &(String.trim(Enum.at(lines, &1)) == "")
             )

      Headless.stop(id)
    end
  end

  describe "alarm prominence (Block.render map)" do
    test "the error header is non-dim (full-weight alarm)" do
      id = start_headless()
      {:ok, %{blocks: blocks}} = Headless.get_model(id)

      header =
        blocks.err_full
        |> Block.render(%{width: 76})
        |> Map.get(:children)
        |> List.first()
        |> Map.get(:style)

      refute Map.get(header, :dim, false)

      Headless.stop(id)
    end
  end

  describe "MCP derivation" do
    test "each block derives a namespaced toggle_fold tool from the live tree" do
      session =
        start_session(HarnessErrorBlockDemo,
          width: 80,
          height: 24,
          settle_ms: @settle_ms
        )

      names = session |> get_tools() |> Enum.map(& &1[:name])

      assert "err_full.toggle_fold" in names
      assert "opq.toggle_fold" in names

      stop_session(session)
    end

    test "the derived tool expands a folded fault through the real seam" do
      session =
        start_session(HarnessErrorBlockDemo,
          width: 80,
          height: 24,
          settle_ms: @settle_ms
        )

      assert %{blocks: %{err_full: %{fold: :folded}}} = get_model(session)
      call_tool(session, "err_full.toggle_fold", %{})
      assert %{blocks: %{err_full: %{fold: :expanded}}} = get_model(session)

      stop_session(session)
    end
  end

  defp start_headless do
    id = :"error_demo_#{System.unique_integer([:positive])}"

    {:ok, ^id} =
      Headless.start(HarnessErrorBlockDemo, id: id, width: 80, height: 24)

    Process.sleep(@settle_ms)
    id
  end

  defp screenshot!(id) do
    {:ok, text} = Headless.screenshot(id)
    text
  end
end
