defmodule Raxol.MCP.StickyToolSetsTest do
  @moduledoc """
  Sticky per-session tool sets, live widget resolution and owned
  registrations, end to end through a private `Raxol.MCP.Registry` and
  `Raxol.MCP.Server` in front of the real `Raxol.Headless`.

  Notifications are checked after a barrier along the session's processes
  (dispatcher, lifecycle, rendering engine, synchronizer, then the server),
  with zero-window `refute_received`.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Raxol.Headless
  alias Raxol.MCP.{Authorizer, Registry, Server, ToolSynchronizer}
  alias Raxol.Playground.Demos.{ModalDemo, TableDemo}

  @list_changed "notifications/tools/list_changed"

  # A checkbox, and a button its own click disables.
  defmodule ControlsApp do
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: %{checked: false, go: :enabled}

    @impl true
    def update({:checkbox_toggle, "agree", checked}, model), do: {%{model | checked: checked}, []}
    def update(:go, model), do: {%{model | go: :disabled}, []}
    def update(_message, model), do: {model, []}

    @impl true
    def view(model) do
      column(
        children: [
          Raxol.View.Components.checkbox(id: "agree", label: "Agree", checked: model.checked),
          "Go" |> button(id: "go", on_click: :go) |> Map.put(:disabled, model.go == :disabled)
        ]
      )
    end
  end

  setup do
    if is_nil(Process.whereis(Headless)),
      do: start_supervised!({Headless, [name: Headless]})

    unique = System.unique_integer([:positive])
    registry = :"sticky_registry_#{unique}"
    server = :"sticky_server_#{unique}"

    {:ok, _} = Registry.start_link(name: registry, server: server)

    {:ok, _} =
      Server.start_link(name: server, registry: registry, authorizer: Authorizer.allow_all())

    :ok = Server.subscribe(server, self())
    :sys.get_state(server)

    on_exit(fn ->
      for id <- Headless.list(), String.starts_with?(id, "k"), do: Headless.stop(id)
    end)

    %{registry: registry, server: server}
  end

  test "a modal opened, dismissed and reopened changes the tool set once", %{server: server} = ctx do
    id = start!(ModalDemo, ctx)

    :ok = Headless.send_key(id, "o")
    barrier(id, server)
    assert_received {:mcp_notification, %{method: @list_changed}}
    refute_received {:mcp_notification, _}
    assert "#{id}.confirm.dismiss" in tool_names(server)

    assert ok_text(call(server, "#{id}.confirm.dismiss")) == "Dismissed modal"
    barrier(id, server)
    assert "#{id}.confirm.dismiss" in tool_names(server)

    assert error_text(call(server, "#{id}.confirm.confirm")) ==
             "widget `confirm` is not in the session's current view"

    :ok = Headless.send_key(id, "o")
    barrier(id, server)
    refute_received {:mcp_notification, _}

    assert {:ok, %{show: true, cancelled: 1}} = Headless.get_model(id)
  end

  test "a checkbox toggled twice flips twice", %{server: server} = ctx do
    id = start!(ControlsApp, ctx)

    assert ok_text(call(server, "#{id}.agree.toggle")) == "Toggled to true"
    assert ok_text(call(server, "#{id}.agree.toggle")) == "Toggled to false"

    assert {:ok, %{checked: false}} = Headless.get_model(id)
  end

  test "a button disabled after its first render answers an error naming it", %{
    server: server
  } = ctx do
    id = start!(ControlsApp, ctx)

    assert ok_text(call(server, "#{id}.go.click")) =~ "Clicked"
    barrier(id, server)
    assert "#{id}.go.click" in tool_names(server)

    assert error_text(call(server, "#{id}.go.click")) ==
             "widget `go` does not offer this action now (disabled)"
  end

  test "sort then get_rows, back to back, answers the rows sorted", %{server: server} = ctx do
    id = start!(TableDemo, ctx)
    sort = %{"column" => "stars", "direction" => "desc"}

    assert ok_text(call(server, "#{id}.playground_table.sort", sort)) =~ "Sorted by stars desc"
    rows = ok_text(call(server, "#{id}.playground_table.get_rows"))

    assert Regex.scan(~r/framework: "([^"]+)"/, rows, capture: :all_but_first) ==
             [["Bubble Tea"], ["Ink"], ["Textual"], ["Blessed"], ["Ratatui"], ["tview"], ["Raxol"]]
  end

  # The registry's owner contract: a synchronizer that dies takes what it owns
  # with it. Not production isolation: a session's own synchronizer is linked
  # to `Raxol.Headless`, which does not trap exits, so killing it takes down
  # Headless and every session; this test kills a second, unlinked one.
  test "the registry drops a dead synchronizer's tools and resources", %{
    registry: registry,
    server: server
  } = ctx do
    id = start!(TableDemo, ctx)
    other = fresh_id()

    {:ok, sync} =
      ToolSynchronizer.start_link(
        registry: GenServer.whereis(registry),
        server: server,
        dispatcher_pid: processes(id).dispatcher,
        session_id: other,
        app_module: TableDemo,
        debounce_ms: 0
      )

    Process.unlink(sync)
    :sys.get_state(server)
    drain_notifications()
    assert "#{other}.playground_table.sort" in tool_names(server)

    ref = Process.monitor(sync)
    Process.exit(sync, :kill)
    assert_receive {:DOWN, ^ref, :process, ^sync, :killed}
    :sys.get_state(registry)
    :sys.get_state(server)

    assert_received {:mcp_notification, %{method: @list_changed}}
    refute_received {:mcp_notification, _}

    names = tool_names(server)
    refute Enum.any?(names, &String.starts_with?(&1, "#{other}."))
    assert "#{id}.playground_table.sort" in names

    uris = registry |> Registry.list_resources() |> Enum.map(& &1.uri)
    refute "raxol://session/#{other}/context" in uris
    assert "raxol://session/#{id}/context" in uris
  end

  defp start!(module, %{registry: registry, server: server}) do
    id = fresh_id()
    {:ok, ^id} = Headless.start(module, id: id, registry: registry, server: server)
    barrier(id, server)
    drain_notifications()
    id
  end

  # Everything sent to the session so far has been through its dispatcher,
  # been rendered, synced into its tool set, and announced by the server.
  defp barrier(id, server) do
    %{dispatcher: dispatcher, lifecycle: lifecycle, engine: engine, synchronizer: sync} =
      processes(id)

    for pid <- [dispatcher, lifecycle, engine, sync], do: :sys.get_state(pid)
    :sys.get_state(server)
    :ok
  end

  defp processes(id) do
    {:ok, session} = GenServer.call(Headless, {:lookup_session, id})
    lifecycle = GenServer.call(session.lifecycle_pid, :get_full_state)

    %{
      dispatcher: lifecycle.dispatcher_pid,
      lifecycle: session.lifecycle_pid,
      engine: lifecycle.rendering_engine_pid,
      synchronizer: session.synchronizer_pid
    }
  end

  defp drain_notifications do
    receive do
      {:mcp_notification, _} -> drain_notifications()
    after
      0 -> :ok
    end
  end

  # Unique per test and per run, inside the `raxol_start` pattern.
  defp fresh_id do
    "k" <> String.downcase(Integer.to_string(System.unique_integer([:positive]), 36))
  end

  defp tool_names(server) do
    {:reply, %{result: %{tools: tools}}} = request(server, "tools/list", %{})
    Enum.map(tools, & &1.name)
  end

  defp call(server, name, arguments \\ %{}),
    do: request(server, "tools/call", %{"name" => name, "arguments" => arguments})

  defp ok_text({:reply, %{result: %{content: [%{text: text} | _]} = result}}) do
    refute Map.get(result, :isError, false), text
    text
  end

  defp error_text({:reply, %{result: %{content: [%{text: text}], isError: true}}}), do: text

  defp request(server, method, params) do
    Server.handle_message(server, %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: method,
      params: params
    })
  end
end
