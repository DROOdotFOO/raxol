defmodule Raxol.Agent.McpSpendHookTest.PricedServer do
  @moduledoc """
  A real GenServer at the same process boundary `Raxol.MCP.Client` sits behind,
  answering `:list_tools` and `{:call_tool, name, args}`. It reports every tool
  call to the test, so "was a request issued" is answered by the server that
  would have served it.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

  @impl true
  def handle_call(:list_tools, _from, state) do
    tools = [
      %{"name" => "lookup", "description" => "priced", "inputSchema" => %{"type" => "object"}},
      %{"name" => "ping", "description" => "unpriced", "inputSchema" => %{"type" => "object"}}
    ]

    {:reply, {:ok, tools}, state}
  end

  def handle_call({:call_tool, name, args, opts}, _from, state) do
    send(state.test_pid, {:requested, name, args, opts})
    {:reply, {:ok, %{"content" => [%{"type" => "text", "text" => "ok"}]}}, state}
  end
end

defmodule Raxol.Agent.McpSpendHookTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Raxol.Agent.Action.Dynamic
  alias Raxol.Agent.Action.ToolConverter
  alias Raxol.Agent.McpBundle
  alias Raxol.Agent.McpSpendHook
  alias Raxol.Agent.McpSpendHookTest.PricedServer
  alias Raxol.Agent.ToolPolicy

  @url "https://mcp.example.com/v1"
  @origin "https://mcp.example.com"

  setup do
    %{tools: load(prices: %{"lookup" => 150})}
  end

  # A remote spec with no headers: header resolution and its provenance rule
  # are exercised in `Raxol.Agent.McpHeadersTest`, and leaving them out here
  # keeps this test independent of the operator's environment.
  defp load(opts) do
    parent = self()

    spec =
      %{
        name: :intel,
        url: @url,
        headers: [],
        source: :user,
        metered: true,
        prices: Keyword.get(opts, :prices, %{})
      }
      |> Map.merge(Map.new(Keyword.get(opts, :spec, [])))

    loaded =
      McpBundle.load([spec],
        start: fn _client_opts -> PricedServer.start_link(test_pid: parent) end
      )

    loaded.tools
  end

  defp tool(tools, name), do: Enum.find(tools, &(&1.name == name))

  defp gate(try_reserve) do
    parent = self()

    %{
      budget_id: {:test, parent},
      emit: fn record -> send(parent, {:cost, record.kind, record.cost_ref}) end,
      try_reserve: try_reserve
    }
  end

  defp context(gate) do
    base = %{tool_authorizer: ToolPolicy.allow_all(), tool_call_hooks: [McpSpendHook]}
    if gate, do: Map.put(base, :spend_gate, gate), else: base
  end

  defp call(tools, name, context, args \\ %{"q" => "x"}) do
    ToolConverter.dispatch_tool_call(%{"name" => name, "arguments" => args}, tools, context)
  end

  defp cost_records(n) do
    for _ <- 1..n do
      receive do
        {:cost, kind, cost_ref} -> {kind, cost_ref}
      after
        500 -> flunk("expected #{n} cost records")
      end
    end
  end

  describe "a priced tool" do
    test "is sensitive and carries its declared price and origin", %{tools: tools} do
      priced = tool(tools, "mcp__intel__lookup")

      assert priced.price == 150
      assert priced.origin == @origin
      assert priced.sensitive == true
    end

    test "cannot opt out of the capability gate through the spec" do
      tools = load(prices: %{"lookup" => 150}, spec: [sensitive: false])

      assert tool(tools, "mcp__intel__lookup").sensitive == true
      # The opt-out still holds for a tool nothing bills.
      assert tool(tools, "mcp__intel__ping").sensitive == false
    end

    test "reserves, calls and settles in that order, handing the request its handle" do
      tools = load(prices: %{"lookup" => 150})

      assert {:ok, _output} =
               call(tools, "mcp__intel__lookup", context(gate(fn 150 -> {:ok, 850} end)))

      assert_receive {:requested, "lookup", args, opts}
      # The reservation rides beside the request, never inside its arguments.
      assert args == %{"q" => "x"}

      assert [{:reserve, ref}, {:call, ref}, {:settle, ref}] = cost_records(3)
      # The handle the transport enforces against is MINTED, and it is not
      # the ledger's `cost_ref`: that one is derived from the model's
      # tool-use id, so a model could name it and the transport could not
      # tell it from a live reservation. This one is spendable once.
      handle = Keyword.fetch!(opts, :reservation)
      refute handle == ref
      reservations = Raxol.MCP.Client.Tables.ensure_started().reservations
      assert Raxol.MCP.Client.Reservation.consume(reservations, handle) == :ok
      assert Raxol.MCP.Client.Reservation.consume(reservations, handle) == :error
    end

    test "a refused reservation issues no request", %{tools: tools} do
      result =
        call(
          tools,
          "mcp__intel__lookup",
          context(gate(fn _estimate -> {:error, :over_limit} end))
        )

      assert {:error, {:reserve_refused, :over_limit}} = result
      refute_received {:requested, _name, _args, _opts}
      assert [{:reserve_refused, _ref}] = cost_records(1)
    end

    test "is denied when no budget seam is wired", %{tools: tools} do
      log =
        capture_log(fn ->
          assert {:error, {:vetoed, {:no_spend_gate, "mcp__intel__lookup", @origin}}} =
                   call(tools, "mcp__intel__lookup", context(nil))
        end)

      refute_received {:requested, _name, _args, _opts}
      assert log =~ "mcp__intel__lookup"
      assert log =~ @origin
    end
  end

  describe "an invalid declared price" do
    test "is denied before it can reach the reservation gate" do
      tool = %Dynamic{
        name: "mcp__intel__lookup",
        origin: @origin,
        price: 0,
        invoke: fn _params, _context -> flunk("invalid-price tool was invoked") end
      }

      call = %{action: tool, params: %{}, call_id: "bad-price"}

      assert {:halt, {:invalid_price, "mcp__intel__lookup", @origin}} =
               McpSpendHook.before_call(call, %{spend_gate: gate(fn _ -> flunk("reserved") end)})
    end
  end

  describe "an unpriced tool on a metered origin" do
    test "is denied by default, naming the tool and the origin", %{tools: tools} do
      log =
        capture_log(fn ->
          assert {:error, {:vetoed, {:unpriced_metered_tool, "mcp__intel__ping", @origin}}} =
                   call(tools, "mcp__intel__ping", context(gate(fn _e -> {:ok, 1} end)))
        end)

      refute_received {:requested, _name, _args, _opts}
      assert log =~ "mcp__intel__ping"
      assert log =~ @origin
    end
  end

  describe "a tool nothing bills" do
    test "runs with no reservation at all" do
      tools = load(spec: [metered: false])

      assert {:ok, _output} =
               call(tools, "mcp__intel__ping", context(gate(fn _e -> flunk("reserved") end)))

      assert_receive {:requested, "ping", _args, opts}
      assert Keyword.get(opts, :reservation) == nil
      refute_received {:cost, _kind, _ref}
    end

    test "refuses a model-supplied reservation key instead of forwarding it" do
      tools = load(spec: [metered: false])

      # Model-supplied names arrive as an atom or a string depending on whether
      # the hook module is loaded yet, so both spellings must refuse.
      for forged <- [%{"__mcp_spend__" => "forged"}, %{__mcp_spend__: "forged"}] do
        assert {:error, :invalid_spend_ticket} =
                 call(tools, "mcp__intel__ping", context(nil), forged)

        refute_received {:requested, _name, _args, _opts}
      end
    end
  end
end
