defmodule Raxol.MCP.DerivedToolMessagesTest do
  @moduledoc """
  Derived write tools, end to end: a `tools/call` through `Raxol.MCP.Server`
  on a real Headless playground demo reaches the demo's `update/2` before the
  call returns, and the session's Dispatcher survives it. One case per B1
  agent task, plus each demo's `tools/list` carrying its task's action.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Raxol.Headless
  alias Raxol.MCP.Server
  alias Raxol.Playground.Demos

  # Buttons whose clicks cannot honestly report success: one without an
  # `on_click`, one whose `on_click` is a function (no message), and one whose
  # message makes update/2 raise.
  defmodule ProbeApp do
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: %{}

    @impl true
    def update(:boom, _model), do: raise("boom")
    def update(_message, model), do: {model, []}

    @impl true
    def view(_model) do
      column(
        children: [
          button("Silent", id: "silent"),
          button("Fn", id: "fn", on_click: fn -> :clicked end),
          button("Boom", id: "boom", on_click: :boom)
        ]
      )
    end
  end

  setup do
    headless = Process.whereis(Headless) || start_supervised!({Headless, [name: Headless]})

    # `mix test` never starts the MCP tree, so the default names are free.
    # Headless syncs derived tools into the registry under its default name,
    # and the synchronizer's `list_changed` goes to the server's. The server
    # is handed the registry's pid: `Raxol.MCP.Registry` caches a named
    # registry's ETS table in `:persistent_term`, so a name reused after an
    # earlier test's registry stopped would resolve to that dead table.
    registry = start_supervised!({Raxol.MCP.Registry, name: Raxol.MCP.Registry})

    server_opts =
      [name: Server, registry: registry] ++ Raxol.Application.mcp_supervisor_opts()

    start_supervised!({Server, server_opts})

    on_exit(fn ->
      if Process.alive?(headless) do
        for id <- GenServer.call(headless, :list_sessions) do
          try do
            GenServer.call(headless, {:stop_session, id}, 2_000)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    :ok
  end

  describe "tools/list" do
    for {demo, id, action} <- [
          {Demos.TableDemo, :list_table, "playground_table.sort"},
          {Demos.SelectListDemo, :list_select_list, "lang.select"},
          {Demos.TextInputDemo, :list_text_input, "input.type_into"},
          {Demos.TabsDemo, :list_tabs, "tabs.select_tab"}
        ] do
      test "#{inspect(demo)} lists #{action}" do
        start_demo(unquote(demo), unquote(id))
        assert unquote(action) in tool_names()
      end
    end

    test "ModalDemo lists confirm.dismiss while the dialog is open" do
      id = start_demo(Demos.ModalDemo, :list_modal)
      refute "confirm.dismiss" in tool_names()

      open_modal(id)
      assert "confirm.dismiss" in tool_names()
    end
  end

  test "table_sort_stars_desc: sort sets the model and keeps the dispatcher" do
    id = start_demo(Demos.TableDemo, :table_sort_stars_desc)
    dispatcher = dispatcher_pid(id)

    assert %{content: [%{text: "Sorted by stars desc"}]} =
             call_tool("playground_table.sort", %{"column" => "stars", "direction" => "desc"})

    {:ok, model} = Headless.get_model(id)
    assert {model.table.sort_by, model.table.sort_direction} == {:stars, :desc}

    # The first page, as drawn from that model: the four most-starred rows.
    {:ok, screen} = Headless.screenshot(id)
    top_four = ["Bubble Tea", "Ink", "Textual", "Blessed"]
    assert Enum.all?(top_four, &(screen =~ &1))
    assert Enum.sort_by(top_four, &screen_offset(screen, &1)) == top_four

    assert dispatcher_pid(id) == dispatcher
    assert Process.alive?(dispatcher)
  end

  test "table sort takes a column label in any case and refuses unknown input" do
    id = start_demo(Demos.TableDemo, :table_sort_validation)

    assert %{content: [%{text: text}]} =
             result =
             call_tool("playground_table.sort", %{"column" => "Stars", "direction" => "sideways"})

    assert error?(result) and text =~ "direction"

    assert %{content: [%{text: text}]} =
             result = call_tool("playground_table.sort", %{"column" => "rank"})

    assert error?(result) and text =~ "Unknown column"

    {:ok, model} = Headless.get_model(id)
    assert model.table.sort_by == nil

    refute error?(call_tool("playground_table.sort", %{"column" => "Stars", "direction" => "desc"}))

    {:ok, model} = Headless.get_model(id)
    assert {model.table.sort_by, model.table.sort_direction} == {:stars, :desc}
  end

  test "select_list_pick: select confirms the option" do
    id = start_demo(Demos.SelectListDemo, :select_list_pick)

    refute error?(call_tool("lang.select", %{"index" => 2}))

    assert {:ok, %{selected: 2, confirmed: "Go", open: false}} = Headless.get_model(id)
  end

  test "modal_dismiss: dismiss closes the dialog as cancelled" do
    id = start_demo(Demos.ModalDemo, :modal_dismiss)
    open_modal(id)

    refute error?(call_tool("confirm.dismiss", %{}))

    assert {:ok, %{show: false, cancelled: 1, confirmed: 0}} = Headless.get_model(id)
  end

  test "text_input_fill: type_into sets the value" do
    id = start_demo(Demos.TextInputDemo, :text_input_fill)

    refute error?(call_tool("input.type_into", %{"text" => "hello"}))

    assert {:ok, %{value: "hello", char_count: 5}} = Headless.get_model(id)
  end

  test "tabs_switch: select_tab activates the tab" do
    id = start_demo(Demos.TabsDemo, :tabs_switch)

    refute error?(call_tool("tabs.select_tab", %{"index" => 2}))

    assert {:ok, %{active: 2}} = Headless.get_model(id)
  end

  test "click on a button without an on_click message is an error result" do
    start_demo(ProbeApp, :probe_no_message)

    for {name, label} <- [{"silent.click", "Silent"}, {"fn.click", "Fn"}] do
      assert %{content: [%{text: text}]} = result = call_tool(name, %{})
      assert error?(result)
      assert text =~ "Button '#{label}' has no on_click message"
    end
  end

  test "a message whose update/2 raises is an error result; the dispatcher survives" do
    id = start_demo(ProbeApp, :probe_update_failed)
    dispatcher = dispatcher_pid(id)

    assert %{content: [%{text: "Error: :update_failed"}]} = result = call_tool("boom.click", %{})
    assert error?(result)

    assert dispatcher_pid(id) == dispatcher
    assert Process.alive?(dispatcher)
  end

  defp start_demo(module, id) do
    {:ok, ^id} = Headless.start(module, id: id, subscriptions: false)
    id
  end

  # The dialog's tools appear after the re-render that opening it causes; the
  # synchronizer announces them with `list_changed` once they are registered.
  defp open_modal(id) do
    Server.subscribe(Server, self())
    :ok = Headless.send_key(id, "o")
    assert_receive {:mcp_notification, %{method: "notifications/tools/list_changed"}}, 5_000
  end

  defp dispatcher_pid(id) do
    {:ok, session} = GenServer.call(Headless, {:lookup_session, id})
    GenServer.call(session.lifecycle_pid, :get_full_state).dispatcher_pid
  end

  defp tool_names do
    %{tools: tools} = request("tools/list", %{})
    Enum.map(tools, & &1.name)
  end

  defp call_tool(name, arguments),
    do: request("tools/call", %{"name" => name, "arguments" => arguments})

  defp request(method, params) do
    {:reply, %{result: result}} =
      Server.handle_message(Server, %{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: method,
        params: params
      })

    result
  end

  defp error?(result), do: Map.get(result, :isError, false)

  defp screen_offset(screen, text), do: screen |> :binary.match(text) |> elem(0)
end
