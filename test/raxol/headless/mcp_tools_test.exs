defmodule Raxol.Headless.McpToolsTest do
  use ExUnit.Case, async: false

  alias Raxol.Headless.McpTools

  # Owns `:tidewave_tools` the way Tidewave does: a `:sys`-reachable process, so
  # `inject_into_tidewave/0`'s `:sys.replace_state` round trip is exercised for
  # real rather than stubbed out.
  defmodule TidewaveTableOwner do
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, %{}}

    @impl true
    def handle_call(:create_table, _from, state) do
      :ets.new(:tidewave_tools, [:set, :named_table, read_concurrency: true])

      :ets.insert(
        :tidewave_tools,
        {:tools,
         {[%{name: "existing_tidewave_tool"}],
          %{"existing_tidewave_tool" => fn _ -> :ok end},
          [%{name: "browser_eval"}], %{"browser_eval" => fn _ -> :ok end}}}
      )

      {:reply, :ok, state}
    end
  end

  describe "tools/0" do
    test "returns 6 tool definitions" do
      tools = McpTools.tools()
      assert length(tools) == 6
    end

    test "each tool has required fields" do
      for tool <- McpTools.tools() do
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_map(tool.inputSchema)
        assert is_function(tool.callback, 1)
      end
    end

    test "tool names follow raxol_ prefix convention" do
      names = Enum.map(McpTools.tools(), & &1.name)

      assert "raxol_start" in names
      assert "raxol_screenshot" in names
      assert "raxol_send_key" in names
      assert "raxol_get_model" in names
      assert "raxol_stop" in names
      assert "raxol_list" in names
    end

    test "input schemas have type: object" do
      for tool <- McpTools.tools() do
        assert tool.inputSchema.type == "object"
      end
    end
  end

  describe "inject_into_tidewave/0" do
    test "returns error when tidewave not started" do
      # In test env, Tidewave ETS table won't exist
      assert {:error, :tidewave_not_started} = McpTools.inject_into_tidewave()
    end

    # Tidewave is `only: :dev`, so nothing in the test env can start it and the
    # case above is the only one CI ever reached. That let the 0.8.2 -> 0.9.0
    # bump silently break injection: the record widened from
    # `{tools, dispatch}` to `{tools, dispatch, browser_tools, browser_dispatch}`
    # and the MatchError disappeared into `{:error, {:sys_replace_failed, _}}`.
    #
    # This stands up the real thing -- a real GenServer owning a real ETS table
    # holding the record Tidewave actually writes (mirrored from
    # `Tidewave.MCP.Handler.init_tools/0`) -- so a future shape change fails here
    # instead of in a dev session nobody is watching.
    test "injects into the tidewave table and leaves the browser halves alone" do
      {:ok, owner} = start_supervised(TidewaveTableOwner)
      GenServer.call(owner, :create_table)

      assert :ok = McpTools.inject_into_tidewave()

      assert [{:tools, {tools, dispatch, browser_tools, browser_dispatch}}] =
               :ets.lookup(:tidewave_tools, :tools)

      names = Enum.map(tools, & &1.name)

      # Tidewave's own tool survived, ours arrived.
      assert "existing_tidewave_tool" in names
      assert "raxol_screenshot" in names
      assert Map.has_key?(dispatch, "raxol_screenshot")

      # The browser halves are Tidewave's; we pass them through untouched.
      assert browser_tools == [%{name: "browser_eval"}]
      assert Map.keys(browser_dispatch) == ["browser_eval"]
    end

    test "is idempotent: a second inject does not duplicate our tools" do
      {:ok, owner} = start_supervised(TidewaveTableOwner)
      GenServer.call(owner, :create_table)

      assert :ok = McpTools.inject_into_tidewave()
      assert :ok = McpTools.inject_into_tidewave()

      [{:tools, {tools, _dispatch, _bt, _bd}}] =
        :ets.lookup(:tidewave_tools, :tools)

      names = Enum.map(tools, & &1.name)

      assert Enum.count(names, &(&1 == "raxol_screenshot")) == 1
      assert length(names) == length(Enum.uniq(names))
    end
  end
end
