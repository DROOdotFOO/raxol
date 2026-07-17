defmodule Raxol.MCP.ButtonDemoMcpSeamTest do
  @moduledoc """
  F0-mcp-headless seam proof: an `Raxol.MCP.Test` session on a REAL
  playground demo derives its MCP tools from the live running app's view
  tree -- no hand-built trees anywhere.

  The loop under proof:

      start_session(ButtonDemo)          # real Headless session
      |> get_tools()                     # tools/list: derived from live tree
      |> click("primary_btn")            # invoke a derived tool
      |> assert_component("click_stats") # widgets resource sees the change
      Headless screenshot                # rendered frame shows the change

  This is the autotest contract from the harness TEA migration (spec Q6):
  every playground demo must be drivable headlessly via MCP with tools
  derived from the Component tree, not from fixtures.
  """
  use ExUnit.Case, async: false

  import Raxol.MCP.Test
  import Raxol.MCP.Test.Assertions

  alias Raxol.Headless
  alias Raxol.Playground.Demos.ButtonDemo

  # Generous settle: covers dispatcher cast + engine re-render + the
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

  test "tools/list returns tools derived from the LIVE demo tree" do
    session =
      start_session(ButtonDemo, width: 80, height: 24, settle_ms: @settle_ms)

    names = session |> get_tools() |> Enum.map(& &1[:name])

    assert "primary_btn.click" in names,
           "expected live-derived button tools, got: #{inspect(names)}"

    assert "secondary_btn.click" in names
    assert "reset_btn.click" in names
    assert "discover_tools" in names

    stop_session(session)
  end

  test "clicking a derived tool drives the real app: model, widget tree, and screenshot all change" do
    session =
      start_session(ButtonDemo, width: 80, height: 24, settle_ms: @settle_ms)

    # Before: the live widgets resource shows the demo's components
    session
    |> assert_component("primary_btn", fn c -> c[:type] == :button end)
    |> assert_component("click_stats", fn c -> c[:content] == "Clicks: 0" end)

    # Invoke the derived tool -- the full MCP pipeline, no shortcuts
    session
    |> click("primary_btn")
    |> assert_model(fn m -> m.clicks == 1 and m.last_action == "primary" end)
    |> assert_component("click_stats", fn c -> c[:content] == "Clicks: 1" end)

    # The rendered frame agrees
    text = screenshot(session)
    assert text =~ "Clicks: 1"
    assert text =~ "Last: primary"

    # A second, different button keeps working
    session
    |> click("secondary_btn")
    |> assert_model(fn m -> m.clicks == 2 and m.last_action == "secondary" end)
    |> assert_component("click_stats", fn c -> c[:content] == "Clicks: 2" end)

    stop_session(session)
  end

  test "session teardown unregisters the session's derived tools" do
    session =
      start_session(ButtonDemo, width: 80, height: 24, settle_ms: @settle_ms)

    assert session
           |> get_tools()
           |> Enum.any?(&(&1[:name] == "primary_btn.click"))

    registry = session.registry
    :ok = Headless.stop(session.id)
    Process.sleep(50)

    names = Raxol.MCP.Registry.list_tools(registry) |> Enum.map(& &1[:name])
    refute "primary_btn.click" in names

    try do
      GenServer.stop(session.registry_pid)
    catch
      :exit, _ -> :ok
    end
  end
end
