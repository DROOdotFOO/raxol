defmodule Raxol.Agent.CausationChainTest do
  @moduledoc """
  End-to-end multi-hop causation tests.

  These tests drive real `Raxol.Agent.Directive.SendAgent` dispatches through
  a chain of agents and assert that each receiver's `causation_id` matches
  the immediate upstream sender's `span_id` -- not the root sender's. The
  load-bearing property is per-hop rotation: causation tracks the immediate
  predecessor, not the trace root.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Raxol.Agent.Directive
  alias Raxol.Agent.Session
  alias Raxol.Core.Telemetry.TraceContext

  @config_table :causation_chain_test_config

  defmodule ChainAgent do
    @moduledoc """
    Each agent in the chain:
      * On `{:agent_message, _, :start_chain}`: reports the current
        causation_id (expected nil) and forwards `:hop`/`:terminal` to
        the next downstream agent (per its configured downstream list).
      * On `{:agent_message, _, :hop}`: same as above (forwards further).
      * On `{:agent_message, _, :terminal}`: reports causation_id and
        stops forwarding.

    Each agent's downstream list and the test pid are looked up from
    `:ets.lookup(:causation_chain_test_config, agent_id)`.
    """

    use Raxol.Agent

    def init(context) do
      id =
        Map.get(context, :__chain_id__) ||
          raise "missing __chain_id__ in context"

      [{^id, config}] = :ets.lookup(:causation_chain_test_config, id)

      %{
        id: id,
        downstream: config.downstream,
        test_pid: config.test_pid
      }
    end

    def update({:agent_message, _from, :start_chain}, model) do
      report(model, nil)
      forward(model)
    end

    def update({:agent_message, _from, :hop}, model) do
      ctx = TraceContext.current()
      report(model, ctx.causation_id)
      forward(model)
    end

    def update({:agent_message, _from, :terminal}, model) do
      ctx = TraceContext.current()
      report(model, ctx.causation_id)
      {model, []}
    end

    def update(_msg, model), do: {model, []}

    defp forward(%{downstream: []} = model), do: {model, []}

    defp forward(%{downstream: [next | rest]} = model) do
      msg = if rest == [], do: :terminal, else: :hop

      send(
        model.test_pid,
        {:about_to_send, model.id, TraceContext.current().span_id}
      )

      new_model = %{model | downstream: rest}
      {new_model, [Directive.send_agent(next, msg)]}
    end

    defp report(model, causation_id) do
      ctx = TraceContext.current()

      send(
        model.test_pid,
        {:captured, model.id,
         %{
           causation_id: causation_id,
           own_span_when_captured: ctx.span_id
         }}
      )
    end
  end

  # Patch Lifecycle's context map so the agent's init can resolve a config
  # via :ets. The agent module reads `context[:__chain_id__]`, which we
  # have to inject by sending it through start_link's `:initial_context`
  # path -- but raxol_agent doesn't expose that, so instead we put the
  # chain id into the process dictionary BEFORE start_link returns, and
  # have a tiny init-shim ChainAgent reads.

  setup do
    if :ets.whereis(@config_table) == :undefined do
      :ets.new(@config_table, [:named_table, :public, read_concurrency: true])
    else
      :ets.delete_all_objects(@config_table)
    end

    start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})

    case Raxol.Core.UserPreferences.start_link(name: Raxol.Core.UserPreferences) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    case DynamicSupervisor.start_link(
           name: Raxol.DynamicSupervisor,
           strategy: :one_for_one
         ) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  defp start_chain_agent(id, downstream, test_pid) do
    :ets.insert(
      @config_table,
      {id, %{downstream: downstream, test_pid: test_pid}}
    )

    # Wrap ChainAgent in a per-id shim so init/1 can find its id.
    shim =
      Module.concat([
        __MODULE__,
        "Shim_#{id}_#{:erlang.unique_integer([:positive])}"
      ])

    defmodule_dynamic(shim, id)

    {:ok, _pid} =
      Session.start_link(app_module: shim, id: id)
  end

  defp defmodule_dynamic(shim, id) do
    contents =
      quote do
        use Raxol.Agent

        def init(context) do
          Raxol.Agent.CausationChainTest.ChainAgent.init(
            Map.put(context, :__chain_id__, unquote(id))
          )
        end

        defdelegate update(msg, model),
          to: Raxol.Agent.CausationChainTest.ChainAgent
      end

    Module.create(shim, contents, Macro.Env.location(__ENV__))
  end

  describe "2-hop chain (A -> B)" do
    test "B's causation_id matches A's span_id at send time" do
      test_pid = self()
      a_id = :chain2_a
      b_id = :chain2_b

      start_chain_agent(b_id, [], test_pid)
      start_chain_agent(a_id, [b_id], test_pid)

      Session.send_message(a_id, :start_chain)

      assert_receive {:about_to_send, ^a_id, a_span}, 500
      assert_receive {:captured, ^b_id, %{causation_id: received}}, 500

      assert is_binary(a_span), "A must have an active span when emitting to B"
      assert received == a_span, "B's causation_id should be A's span_id"
    end
  end

  describe "3-hop chain (A -> B -> C)" do
    test "C's causation_id is B's span_id, not A's" do
      test_pid = self()
      a_id = :chain3_a
      b_id = :chain3_b
      c_id = :chain3_c

      start_chain_agent(c_id, [], test_pid)
      start_chain_agent(b_id, [c_id], test_pid)
      start_chain_agent(a_id, [b_id, c_id], test_pid)

      Session.send_message(a_id, :start_chain)

      assert_receive {:about_to_send, ^a_id, a_span}, 500
      assert_receive {:about_to_send, ^b_id, b_span}, 500
      assert_receive {:captured, ^c_id, %{causation_id: c_received}}, 500

      assert is_binary(a_span)
      assert is_binary(b_span)
      assert a_span != b_span, "A and B must have distinct span_ids"

      assert c_received == b_span,
             "C's causation_id should be B's span_id (immediate sender), not A's (root)"

      refute c_received == a_span,
             "C's causation_id should NOT be A's span_id -- causation rotates per hop"
    end
  end

  describe "absent causation" do
    test "external message without metadata leaves causation_id nil at receiver" do
      test_pid = self()
      id = :no_causation_a

      start_chain_agent(id, [], test_pid)

      Session.send_message(id, :terminal)

      assert_receive {:captured, ^id, %{causation_id: nil}}, 500
    end
  end

  describe "property: N-hop chain causation invariant" do
    @doc """
    For any chain of N agents (2 <= N <= 5), the load-bearing invariant
    is that at hop k (1 <= k < N), the receiver A_k captures
    `causation_id == span_id` recorded by sender A_{k-1} at send time.

    The 2-hop and 3-hop example tests above pin specific cases; this
    property test exercises variable N to catch off-by-one errors,
    accidental root-span propagation, or state leakage between hops.
    """
    property "causation_id at hop k equals span_id at hop k-1" do
      check all(chain_length <- integer(2..5), max_runs: 25) do
        drain_mailbox()
        test_pid = self()
        nonce = :erlang.unique_integer([:positive])

        ids =
          Enum.map(0..(chain_length - 1), fn idx ->
            :"prop_chain_#{nonce}_#{idx}"
          end)

        # Build agents in reverse order so each agent's downstream is alive
        # when it's registered.
        Enum.reverse(ids)
        |> Enum.with_index()
        |> Enum.each(fn {id, rev_idx} ->
          downstream =
            ids
            |> Enum.drop(chain_length - rev_idx)

          start_chain_agent(id, downstream, test_pid)
        end)

        [root | _] = ids
        Session.send_message(root, :start_chain)

        # Senders are A_0..A_{N-2} (count = N-1); captures arrive from
        # all N agents (root reports causation_id=nil), so collect N.
        sends = collect_sends(chain_length - 1, [], 1_000)
        captures = collect_captures(chain_length, [], 1_000)

        # Senders are A_0 .. A_{N-2}; receivers are A_1 .. A_{N-1}.
        # The invariant: for each hop k (1..N-1), receiver A_k's
        # captured causation_id equals sender A_{k-1}'s span_id.
        for k <- 1..(chain_length - 1) do
          sender_id = Enum.at(ids, k - 1)
          receiver_id = Enum.at(ids, k)

          sender_span = sends[sender_id]
          receiver_causation = captures[receiver_id]

          assert is_binary(sender_span),
                 "expected sender #{inspect(sender_id)} to record a binary span_id"

          assert receiver_causation == sender_span,
                 "hop #{k}: receiver #{inspect(receiver_id)} captured " <>
                   "causation #{inspect(receiver_causation)}, " <>
                   "expected sender #{inspect(sender_id)} span " <>
                   "#{inspect(sender_span)}"
        end

        # Span_ids must be distinct across senders (would otherwise mask
        # a "C sees A not B" bug as a false positive when spans collide).
        sent_spans = Enum.map(sends, fn {_, span} -> span end)
        assert sent_spans == Enum.uniq(sent_spans), "sender span_ids collided"

        # Cleanup: stop the agents so the next iteration's ids are fresh.
        for id <- ids, do: stop_chain_agent(id)
      end
    end
  end

  defp collect_sends(expected, acc, deadline) when length(acc) == expected do
    _ = deadline
    Map.new(acc)
  end

  defp collect_sends(expected, acc, deadline) do
    receive do
      {:about_to_send, id, span} ->
        collect_sends(expected, [{id, span} | acc], deadline)
    after
      deadline -> Map.new(acc)
    end
  end

  defp collect_captures(expected, acc, deadline) when length(acc) == expected do
    _ = deadline
    Map.new(acc)
  end

  defp collect_captures(expected, acc, deadline) do
    receive do
      {:captured, id, %{causation_id: cid}} ->
        collect_captures(expected, [{id, cid} | acc], deadline)
    after
      deadline -> Map.new(acc)
    end
  end

  defp stop_chain_agent(id) do
    case Registry.lookup(Raxol.Agent.Registry, id) do
      [{pid, _}] ->
        Process.unlink(pid)
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          200 -> :ok
        end

      [] ->
        :ok
    end
  end

  defp drain_mailbox do
    receive do
      {:about_to_send, _, _} -> drain_mailbox()
      {:captured, _, _} -> drain_mailbox()
    after
      0 -> :ok
    end
  end
end
