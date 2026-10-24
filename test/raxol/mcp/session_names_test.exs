defmodule Raxol.MCP.SessionNamesTest do
  @moduledoc """
  Session-scoped derived tool names, end to end through a private
  `Raxol.MCP.Registry` and `Raxol.MCP.Server` in front of the real
  `Raxol.Headless`: derived tools are `<session>.<widget>.<action>`, a name
  OMP would merge with an existing one is refused, and a call into a stopped
  session says so.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Raxol.Headless
  alias Raxol.Headless.McpTools
  alias Raxol.MCP.{Authorizer, Registry, Server}

  @table "Raxol.Playground.Demos.TableDemo"

  # Two widgets whose tool names differ only where OMP turns `-` and `_`
  # alike into `_`: `<id>.x_y.click` and `<id>.x-y.click` reach it as one name.
  defmodule CollidingApp do
    use Raxol.Core.Runtime.Application

    alias Raxol.Core.Renderer.View

    @impl true
    def init(_context), do: %{}

    @impl true
    def update(_message, model), do: {model, []}

    @impl true
    def view(_model) do
      View.column(
        children: [
          View.button("first", id: "x_y", on_click: :first),
          View.button("second", id: "x-y", on_click: :second)
        ]
      )
    end
  end

  setup do
    if is_nil(Process.whereis(Headless)),
      do: start_supervised!({Headless, [name: Headless]})

    registry = :"registry_#{System.unique_integer([:positive])}"
    server = :"server_#{System.unique_integer([:positive])}"

    {:ok, _} = Registry.start_link(name: registry)
    authorizer = Authorizer.allow_all()
    {:ok, _} = Server.start_link(name: server, registry: registry, authorizer: authorizer)
    :ok = McpTools.register(registry)

    on_exit(fn ->
      for id <- Headless.list(), String.starts_with?(id, "n"), do: Headless.stop(id)
    end)

    %{server: server, registry: registry}
  end

  test "two sessions of one app each own their tools; stopping one leaves the other", %{
    server: server
  } do
    a = fresh_id()
    b = fresh_id()
    start!(server, @table, a)
    start!(server, @table, b)

    names = tool_names(server)
    assert "#{a}.playground_table.sort" in names
    assert "#{b}.playground_table.sort" in names
    assert "#{a}.discover_tools" in names
    assert "#{b}.discover_tools" in names

    assert ok_text(call(server, "#{a}.playground_table.sort", sort("stars", "desc"))) =~
             "Sorted by stars desc"

    assert ok_text(call(server, "#{b}.playground_table.sort", sort("framework", "asc"))) =~
             "Sorted by framework asc"

    assert sort_of(a) == {:stars, :desc}
    assert sort_of(b) == {:framework, :asc}

    assert ok_text(call(server, "raxol_stop", %{"id" => b})) =~ "stopped"
    refute "#{b}.playground_table.sort" in tool_names(server)

    assert ok_text(call(server, "#{a}.playground_table.sort", sort("stars", "asc"))) =~
             "Sorted by stars asc"

    assert sort_of(a) == {:stars, :asc}
  end

  test "a call into a stopped session is a tool error naming the session", %{server: server} do
    id = fresh_id()
    start!(server, @table, id)
    assert ok_text(call(server, "raxol_stop", %{"id" => id})) =~ "stopped"

    for name <- ["#{id}.playground_table.sort", "#{id}.discover_tools"] do
      assert {:reply, %{result: %{isError: true, content: [%{text: text}]}}} =
               request(server, "tools/call", %{"name" => name, "arguments" => %{}})

      assert text == "session `#{id}` is not running in this server; call raxol_list"
    end
  end

  # Only a segment `raxol_start` could have accepted is reported as a stopped
  # session; anything else is an unknown tool, and is not echoed as a session.
  test "a call whose session segment is not a session id is tool-not-found", %{
    server: server
  } do
    for name <- ["Bad.w.a", "abcdefgh.w.a", "a_b.w.a", "x`y\n.discover_tools"] do
      assert {:reply, %{error: %{code: -32_601}}} =
               request(server, "tools/call", %{"name" => name, "arguments" => %{}})
    end
  end

  test "raxol_start refuses the reserved ids raxol and agent", %{server: server} do
    before = Headless.list()

    for id <- ["raxol", "agent"] do
      assert {:reply, %{result: %{isError: true, content: [%{text: text}]}}} =
               call(server, "raxol_start", %{"module" => @table, "id" => id})

      assert text =~ "is reserved"
      assert text =~ id
    end

    assert Headless.list() == before
  end

  test "a widget whose client-side name is already taken is refused, and logged once", %{
    server: server,
    registry: registry
  } do
    id = fresh_id()

    log =
      ExUnit.CaptureLog.capture_log([level: :warning], fn ->
        {:ok, ^id} = Headless.start(CollidingApp, id: id, registry: registry)

        # Every render offers the refused tool again.
        for _ <- 1..3 do
          :ok = Headless.send_key(id, "z")
          :ok = Headless.settle(id)
        end
      end)

    # One of the pair registers (the walk decides which); the other is refused.
    pair = ["#{id}.x_y.click", "#{id}.x-y.click"]
    assert [held] = Enum.filter(pair, &(&1 in tool_names(server)))
    [refused] = pair -- [held]

    assert length(String.split(log, "Session #{inspect(id)}: refused")) == 2

    tool = %{name: refused, description: "d", inputSchema: %{}, callback: & &1}

    assert Registry.register_tools(registry, [tool]) ==
             {:error, {:name_collision, [{refused, held}]}}
  end

  # Unique per test and per run, and inside the `raxol_start` pattern: "n"
  # then the base-36 digits of a fresh integer.
  defp fresh_id do
    id = "n" <> String.downcase(Integer.to_string(System.unique_integer([:positive]), 36))
    assert id =~ ~r/\A[a-z][a-z0-9]{0,6}\z/
    id
  end

  defp start!(server, module, id) do
    assert ok_text(call(server, "raxol_start", %{"module" => module, "id" => id})) ==
             "Session started: #{id}"
  end

  defp sort(column, direction), do: %{"column" => column, "direction" => direction}

  defp sort_of(id) do
    {:ok, model} = Headless.get_model(id)
    {model.table.sort_by, model.table.sort_direction}
  end

  defp tool_names(server) do
    {:reply, %{result: %{tools: tools}}} = request(server, "tools/list", %{})
    Enum.map(tools, & &1.name)
  end

  defp call(server, name, arguments),
    do: request(server, "tools/call", %{"name" => name, "arguments" => arguments})

  defp ok_text({:reply, %{result: %{content: [%{text: text} | _]} = result}}) do
    refute Map.get(result, :isError, false), text
    text
  end

  defp request(server, method, params) do
    Server.handle_message(server, %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: method,
      params: params
    })
  end
end
