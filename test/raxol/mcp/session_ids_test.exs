defmodule Raxol.MCP.SessionIdsTest do
  @moduledoc """
  Binary session ids, end to end through a private `Raxol.MCP.Registry` and
  `Raxol.MCP.Server` in front of the real `Raxol.Headless`: `raxol_start`
  refuses an id outside `^[a-z][a-z0-9]{0,6}$` (and a missing one) rather
  than substituting a name, and no MCP-supplied session id becomes an atom.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Raxol.Headless
  alias Raxol.Headless.McpTools
  alias Raxol.MCP.{Authorizer, Registry, Server}

  @table "Raxol.Playground.Demos.TableDemo"

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

    %{server: server}
  end

  test "an id outside the pattern is refused, never replaced", %{server: server} do
    before = Headless.list()

    for id <- ["Bad_id", "a.b", "abcdefgh", "ab\n", 5] do
      assert {:reply, %{result: %{isError: true, content: [%{text: text}]}}} =
               request(server, "tools/call", %{
                 "name" => "raxol_start",
                 "arguments" => %{"module" => @table, "id" => id}
               })

      assert text =~ "is refused"
    end

    assert {:reply, %{result: %{isError: true, content: [%{text: text}]}}} =
             request(server, "tools/call", %{
               "name" => "raxol_start",
               "arguments" => %{"module" => @table}
             })

    assert text =~ "'id' is required"
    assert Headless.list() == before
  end

  # Five failures in a row open a tool's circuit for every client; a refusal
  # is an answer about the call, not a sign the tool is down.
  test "refusals do not open raxol_start's circuit", %{server: server} do
    for id <- ["Bad_id", "a.b", "abcdefgh", "ab\n", 5, nil] do
      assert {:reply, %{result: %{isError: true}}} =
               call(server, "raxol_start", %{"module" => @table, "id" => id})
    end

    start!(server, @table, fresh_id())
  end

  test "raxol_stop refuses an id no session has", %{server: server} do
    id = fresh_id()

    assert {:reply, %{result: %{isError: true, content: [%{text: text}]}}} =
             call(server, "raxol_stop", %{"id" => id})

    assert text =~ "session #{id} is not running"
  end

  test "session id completion answers live ids, and [] for a non-string", %{
    server: server
  } do
    id = fresh_id()
    start!(server, @table, id)

    assert complete(server, id) == [id]
    assert complete(server, 5) == []
  end

  test "no session id becomes an atom", %{server: server} do
    ids = for _ <- 1..3, do: fresh_id()

    for id <- ids do
      assert_raise ArgumentError, fn -> String.to_existing_atom(id) end
    end

    for id <- ids do
      start!(server, @table, id)
      assert id in Headless.list()
      ok_text(call(server, "playground_table.sort", sort("stars", "desc")))
      ok_text(call(server, "raxol_screenshot", %{"id" => id}))
      ok_text(call(server, "raxol_stop", %{"id" => id}))
    end

    for id <- ids do
      assert_raise ArgumentError, fn -> String.to_existing_atom(id) end
    end
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

  defp call(server, name, arguments),
    do: request(server, "tools/call", %{"name" => name, "arguments" => arguments})

  defp complete(server, value) do
    assert {:reply, %{result: %{completion: %{values: values}}}} =
             request(server, "completion/complete", %{
               "ref" => %{"type" => "ref/tool", "name" => "raxol_stop"},
               "argument" => %{"name" => "id", "value" => value}
             })

    values
  end

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
