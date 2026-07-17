defmodule Raxol.MCP.HarnessDiffDemoMcpSeamTest do
  @moduledoc """
  U1-b seam proof (harness TEA migration sections 6-7): the diff block
  demo is drivable headlessly via MCP with tools derived from the LIVE
  Component tree -- the `button_demo_mcp_seam_test.exs` contract applied
  to `Raxol.Playground.Demos.HarnessDiffDemo`.

  The loop under proof:

      start_session(HarnessDiffDemo)      # real Headless session
      |> get_tools()                      # fold/hunks/sample buttons derive
      |> click("fold_btn")                # full Pierre body -> compact ± line
      |> assert_model(& &1.diff.folded)   # the model owns the fold (controlled)
      StructuredScreenshot                # semantic tree shows both forms
  """
  use ExUnit.Case, async: false

  import Raxol.MCP.Test
  import Raxol.MCP.Test.Assertions

  alias Raxol.Headless
  alias Raxol.Playground.Demos.HarnessDiffDemo

  # Generous settle: dispatcher cast + engine re-render + the
  # ToolSynchronizer's 50ms debounce on slow CI machines.
  @settle_ms 250

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

  defp find_by_id(nodes, id) when is_list(nodes),
    do: Enum.find_value(nodes, &find_by_id(&1, id))

  defp find_by_id(%{id: id} = node, id), do: node

  defp find_by_id(%{children: children}, id), do: find_by_id(children, id)

  defp find_by_id(_node, _id), do: nil

  defp subtree_texts(%{} = node) do
    own =
      case node do
        %{content: content} when is_binary(content) -> [content]
        _ -> []
      end

    own ++ Enum.flat_map(Map.get(node, :children, []), &subtree_texts/1)
  end

  test "tools/list returns tools derived from the LIVE demo tree" do
    session =
      start_session(HarnessDiffDemo,
        width: 120,
        height: 40,
        settle_ms: @settle_ms
      )

    names = session |> get_tools() |> Enum.map(& &1[:name])

    assert "fold_btn.click" in names,
           "expected live-derived demo tools, got: #{inspect(names)}"

    assert "hunks_btn.click" in names
    assert "sample_btn.click" in names

    stop_session(session)
  end

  test "clicking fold_btn folds the diff to the compact form and back" do
    session =
      start_session(HarnessDiffDemo,
        width: 120,
        height: 40,
        settle_ms: @settle_ms
      )

    # Before: expanded Pierre body, status says so, the stamped diff root
    # is visible to the widgets resource.
    session
    |> assert_component("harness_diff")
    |> assert_component("diff_status", fn c -> c[:content] =~ "expanded" end)
    |> assert_model(fn m -> m.diff.folded == false end)

    assert screenshot(session) =~ "Proposed change"

    # Invoke the derived tool -- the full MCP pipeline, no shortcuts.
    session
    |> click("fold_btn")
    |> assert_model(fn m -> m.diff.folded == true end)
    |> assert_component("diff_status", fn c -> c[:content] =~ "folded" end)

    folded_text = screenshot(session)
    assert folded_text =~ "± lib/orders/total.ex"
    refute folded_text =~ "Proposed change"

    # And back.
    session
    |> click("fold_btn")
    |> assert_model(fn m -> m.diff.folded == false end)

    assert screenshot(session) =~ "Proposed change"

    stop_session(session)
  end

  test "hunks_btn and sample_btn drive the engine knobs through MCP" do
    session =
      start_session(HarnessDiffDemo,
        width: 120,
        height: 40,
        settle_ms: @settle_ms
      )

    session
    |> assert_model(fn m -> m.diff.context == 3 end)
    |> click("hunks_btn")
    |> assert_model(fn m -> m.diff.context == :all end)
    |> click("hunks_btn")
    |> assert_model(fn m -> m.diff.context == 3 end)

    session
    |> click("sample_btn")
    |> assert_model(fn m -> m.sample == 1 end)
    |> assert_component("diff_status", fn c ->
      c[:content] =~ "within-line replace"
    end)

    stop_session(session)
  end

  test "StructuredScreenshot shows the stamped diff root in both fold states" do
    session =
      start_session(HarnessDiffDemo,
        width: 120,
        height: 40,
        settle_ms: @settle_ms
      )

    expanded = find_by_id(get_structured_components(session), "harness_diff")
    assert expanded, "expected the stamped harness_diff node in the tree"
    assert expanded.type == :column
    assert length(expanded.children) > 2

    session |> click("fold_btn") |> assert_model(fn m -> m.diff.folded end)

    folded = find_by_id(get_structured_components(session), "harness_diff")
    assert folded
    assert [compact_row] = folded.children
    assert "±" in subtree_texts(compact_row)
    assert "lib/orders/total.ex" in subtree_texts(compact_row)

    stop_session(session)
  end
end
