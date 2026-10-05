defmodule Raxol.Broker.JournalTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.FileStore.Writer
  alias Raxol.Broker.{Intent, Journal, Policy, PolicyFile}
  alias Raxol.Broker.Journal.{Codec, Replay}
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.ExecutorIdentity

  @moduletag :capture_log
  @t0 ~U[2026-10-02 14:30:00.000000Z]
  @day ~U[2026-10-02 00:00:00.000000Z]

  setup do
    base = Path.join(System.tmp_dir!(), "broker-journal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    {:ok, clock} = Agent.start_link(fn -> @t0 end)
    name = :"broker_journal_#{System.unique_integer([:positive])}"
    opts = [name: name, path: Path.join(base, "journal"), clock: fn -> Agent.get(clock, & &1) end]
    {:ok, opts: opts, name: name, clock: clock, path: Path.join(base, "journal")}
  end

  defp d(value), do: Decimal.new(value)

  # Start a journal and claim it for the test process, the only writer of
  # `placing`. The journal only lets an Executor claim, so the test process
  # impersonates one.
  defp start!(opts) do
    pid = start_supervised!(Supervisor.child_spec({Journal, opts}, restart: :temporary))
    ExecutorIdentity.assume!(opts[:name])
    pid
  end

  defp at(clock, datetime), do: Agent.update(clock, fn _ -> datetime end)

  defp context(overrides \\ []) do
    {:ok, policy} = PolicyFile.new(d("1000"), d("5000"))

    struct!(
      %Context{
        policy: policy,
        portfolio_value: d("100000"),
        start_of_day_value: d("100000"),
        day_pnl: d("0"),
        quotes: %{"AAPL" => d("125")},
        today_notional: d("0"),
        orders_last_minute: 0,
        market_session: :regular
      },
      overrides
    )
  end

  defp limit(qty, price \\ "125") do
    {:ok, intent} = Intent.limit(:buy, "AAPL", d(qty), d(price), provenance: :strategy)
    intent
  end

  # The full happy path: both policy passes allow, the order is marked as
  # placing and then placed.
  defp placed_entries(intent, context, response \\ nil) do
    {:allow, _} = verdict = Policy.evaluate(intent, context)

    [
      {:verdict, :pre_review, verdict},
      {:review, %{"warnings" => []}},
      {:verdict, :post_review, verdict},
      {:placing},
      {:order, :placed, response || %{"order_id" => "o-#{intent.id}"}}
    ]
  end

  # Open a group and write it up to (not including) the order call: both
  # passes allow, then `placing`.
  defp in_flight!(name, intent, context) do
    {:ok, id} = Journal.open_group(intent, context, name)

    placed_entries(intent, context)
    |> Enum.drop(-1)
    |> Enum.each(&(:ok = Journal.append_to_group(id, &1, name)))

    id
  end

  defp counters(name, now) do
    {Journal.today_notional(@day, name), Journal.orders_last_minute(now, name)}
  end

  defp records(path) do
    {base, session} = Journal.location(path)
    {:ok, records} = FileStore.read_records(session, base_dir: base)
    records
  end

  defp kill_writer!(path, journal) do
    {base, session} = Journal.location(path)
    writer = :global.whereis_name({Writer, Path.join(base, session)})
    ref = Process.monitor(journal)
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^ref, :process, ^journal, {:journal_writer_down, :killed}}, 5_000
  end

  describe "writing groups" do
    test "a whole group lands as contiguous records sharing one group id", %{
      opts: opts,
      path: path
    } do
      start!(opts)
      intent = limit("2")
      ctx = context()

      assert {:ok, id} =
               Journal.append_group(
                 %{intent: intent, context: ctx, entries: placed_entries(intent, ctx)},
                 opts[:name]
               )

      records = records(path)

      assert Enum.map(records, & &1["type"]) ==
               ~w(intent context verdict review verdict placing order)

      assert Enum.all?(records, &(&1["group_id"] == id))
      assert Enum.map(records, & &1["id"]) == Enum.to_list(1..7)
      assert %{"type" => "placing", "notional" => "250"} = Enum.at(records, 5)

      [intent_record, context_record | _] = records
      assert Codec.decode_intent(intent_record["intent"]) == {:ok, intent}
      assert Codec.decode_context(context_record["context"]) == {:ok, ctx}

      assert Journal.today_notional(@day, opts[:name]) == {:ok, d("250")}
      assert Journal.verify(opts[:name]) == :ok
    end

    test "write-ahead: the intent is on disk before any verdict, and a deny finishes the group",
         %{opts: opts, path: path} do
      start!(opts)
      intent = limit("100")
      ctx = context()

      assert {:ok, id} = Journal.open_group(intent, ctx, opts[:name])
      assert Enum.map(records(path), & &1["type"]) == ~w(intent context)

      {:deny, {:max_notional_per_order, _}} = verdict = Policy.evaluate(intent, ctx)
      assert :ok = Journal.append_to_group(id, {:verdict, :pre_review, verdict}, opts[:name])

      assert Journal.append_to_group(id, {:review, %{}}, opts[:name]) ==
               {:error, {:unknown_or_finished_group, id}}

      assert Journal.today_notional(@day, opts[:name]) == {:ok, d("0")}
    end

    test "invalid entries are refused and append nothing", %{opts: opts, path: path} do
      start!(opts)
      intent = limit("2")
      ctx = context()
      {:ok, id} = Journal.open_group(intent, ctx, opts[:name])

      assert {:error, {:invalid_entry, _}} =
               Journal.append_to_group(id, {:verdict, :final, {:allow, intent}}, opts[:name])

      assert {:error, {:invalid_result, _}} =
               Journal.append_to_group(id, {:verdict, :pre_review, :yes}, opts[:name])

      # Nothing may follow the terminal record of a one-shot group either.
      entries = Enum.concat(placed_entries(intent, ctx), [{:review, %{}}])

      assert {:error, {:group_finished, _}} =
               Journal.append_group(
                 %{intent: intent, context: ctx, entries: entries},
                 opts[:name]
               )

      assert length(records(path)) == 2
    end

    test "an order response is refused before placing, in either write path",
         %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      intent = limit("2")
      ctx = context()
      {:ok, id} = Journal.open_group(intent, ctx, name)

      assert Journal.append_to_group(id, {:order, :placed, %{}}, name) ==
               {:error, {:not_placing, id}}

      entries = List.delete(placed_entries(intent, ctx), {:placing})

      assert {:error, {:not_placing, _}} =
               Journal.append_group(%{intent: intent, context: ctx, entries: entries}, name)

      assert length(records(path)) == 2
      assert Journal.orders_last_minute(@t0, name) == {:ok, 0}
    end

    test "placing an order the journal cannot price is refused", %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      {:ok, intent} = Intent.buy_shares("MSFT", d("3"), provenance: :strategy)
      ctx = context()
      {:ok, id} = Journal.open_group(intent, ctx, name)
      reviewed = [{:review, %{"warnings" => []}}, {:verdict, :post_review, {:allow, intent}}]
      Enum.each(reviewed, &(:ok = Journal.append_to_group(id, &1, name)))

      assert {:error, {:unpriced_order, _reason}} =
               Journal.append_to_group(id, {:placing}, name)

      assert {:error, {:unpriced_order, _reason}} =
               Journal.append_group(
                 %{intent: intent, context: ctx, entries: Enum.concat(reviewed, [{:placing}])},
                 name
               )

      assert Enum.map(records(path), & &1["type"]) == ~w(intent context review verdict)

      assert Journal.append_to_group(id, {:order, :placed, %{}}, name) ==
               {:error, {:not_placing, id}}
    end

    test "after placing only an order response or a close is taken", %{opts: opts} do
      name = opts[:name]
      start!(opts)
      intent = limit("2")
      ctx = context()
      id = in_flight!(name, intent, ctx)

      for entry <- [
            {:placing},
            {:review, %{}},
            {:approval, :approved, "operator"},
            {:verdict, :post_review, Policy.evaluate(intent, ctx)}
          ] do
        assert Journal.append_to_group(id, entry, name) == {:error, {:already_placing, id}}
      end

      assert :ok = Journal.append_to_group(id, {:order, :placed, %{}}, name)
    end

    test "a process that does not hold the claim can write no group record",
         %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      intent = limit("2")
      ctx = context()
      {:ok, id} = Journal.open_group(intent, ctx, name)

      placed_entries(intent, ctx)
      |> Enum.take(1)
      |> Enum.each(&(:ok = Journal.append_to_group(id, &1, name)))

      before = records(path)

      # A forged review, a post-review verdict or approval to unlock placing,
      # a close to end the executor's group, or placing itself: all refused.
      forged = [
        {:review, %{"warnings" => []}},
        {:verdict, :post_review, Policy.evaluate(intent, ctx)},
        {:approval, :approved, "mallory"},
        {:close, :forged},
        {:placing}
      ]

      other =
        Task.async(fn ->
          for entry <- forged, do: Journal.append_to_group(id, entry, name)
        end)

      assert Task.await(other) == List.duplicate({:error, {:not_claimant, id}}, length(forged))

      group = %{intent: limit("2"), context: ctx, entries: placed_entries(limit("2"), ctx)}

      other =
        Task.async(fn ->
          {Journal.open_group(limit("2"), ctx, name), Journal.append_group(group, name)}
        end)

      assert Task.await(other) ==
               {{:error, {:not_claimant, nil}}, {:error, {:not_claimant, nil}}}

      assert records(path) == before
      assert Journal.open_groups(name) == {:ok, [id]}

      placed_entries(intent, ctx)
      |> Enum.slice(1..3)
      |> Enum.each(&(:ok = Journal.append_to_group(id, &1, name)))
    end

    test "placing is refused without a review, and on an ASK without approval",
         %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      ctx = context()
      intent = limit("2")
      allow = Policy.evaluate(intent, ctx)

      # An ALLOW with no review record.
      {:ok, id} = Journal.open_group(intent, ctx, name)
      :ok = Journal.append_to_group(id, {:verdict, :pre_review, allow}, name)
      :ok = Journal.append_to_group(id, {:verdict, :post_review, allow}, name)
      assert Journal.append_to_group(id, {:placing}, name) == {:error, {:not_reviewed, id}}

      # A review with no post-review verdict.
      {:ok, id} = Journal.open_group(limit("2"), ctx, name)
      :ok = Journal.append_to_group(id, {:review, %{"warnings" => []}}, name)
      assert Journal.append_to_group(id, {:placing}, name) == {:error, {:not_reviewed, id}}

      # An ASK, reviewed, never approved.
      {:ok, ask_intent} = Intent.limit(:buy, "AAPL", d("2"), d("125"), provenance: :llm)
      {:ask, _} = ask = Policy.evaluate(ask_intent, ctx)

      entries = [
        {:verdict, :pre_review, ask},
        {:review, %{"warnings" => []}},
        {:verdict, :post_review, ask},
        {:placing}
      ]

      assert {:error, {:not_reviewed, _}} =
               Journal.append_group(%{intent: ask_intent, context: ctx, entries: entries}, name)

      refute Enum.any?(records(path), &(&1["type"] == "placing"))
    end

    test "a reviewed ASK with an approval may be placed", %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      ctx = context()
      {:ok, intent} = Intent.limit(:buy, "AAPL", d("2"), d("125"), provenance: :llm)
      {:ask, _} = ask = Policy.evaluate(intent, ctx)

      entries = [
        {:verdict, :pre_review, ask},
        {:review, %{"warnings" => []}},
        {:verdict, :post_review, ask},
        {:approval, :approved, "operator"},
        {:placing}
      ]

      assert {:ok, id} =
               Journal.append_group(%{intent: intent, context: ctx, entries: entries}, name)

      assert %{"type" => "placing", "group_id" => ^id} = List.last(records(path))
    end

    test "a second placing for the same intent is refused until the first fails",
         %{opts: opts} do
      name = opts[:name]
      start!(opts)
      ctx = context()
      intent = limit("2")
      first = in_flight!(name, intent, ctx)

      {:ok, second} = Journal.open_group(intent, ctx, name)

      placed_entries(intent, ctx)
      |> Enum.take(3)
      |> Enum.each(&(:ok = Journal.append_to_group(second, &1, name)))

      assert Journal.append_to_group(second, {:placing}, name) ==
               {:error, {:duplicate_intent, first}}

      assert {:error, {:duplicate_intent, ^first}} =
               Journal.append_group(
                 %{intent: intent, context: ctx, entries: placed_entries(intent, ctx)},
                 name
               )

      assert Journal.placing_for_intent(intent.id, name) == {:ok, first}

      :ok = Journal.append_to_group(first, {:order, :failed, %{"error" => "rejected"}}, name)
      assert Journal.placing_for_intent(intent.id, name) == {:ok, nil}

      assert :ok = Journal.append_to_group(second, {:placing}, name)
      assert Journal.placing_for_intent(intent.id, name) == {:ok, second}
    end

    test "the intent index rebuilt on start skips failed orders", %{opts: opts} do
      name = opts[:name]
      start!(opts)
      ctx = context()
      failed = limit("2")
      placed = limit("2")

      entries =
        List.replace_at(placed_entries(failed, ctx), -1, {:order, :failed, %{"error" => "no"}})

      {:ok, _} = Journal.append_group(%{intent: failed, context: ctx, entries: entries}, name)

      {:ok, placed_id} =
        Journal.append_group(
          %{intent: placed, context: ctx, entries: placed_entries(placed, ctx)},
          name
        )

      stop_supervised!(name)
      start!(opts)

      assert Journal.placing_for_intent(failed.id, name) == {:ok, nil}
      assert Journal.placing_for_intent(placed.id, name) == {:ok, placed_id}

      assert {:ok, _} =
               Journal.append_group(
                 %{intent: failed, context: ctx, entries: placed_entries(failed, ctx)},
                 name
               )

      assert {:error, {:duplicate_intent, ^placed_id}} =
               Journal.append_group(
                 %{intent: placed, context: ctx, entries: placed_entries(placed, ctx)},
                 name
               )
    end

    test "a second live claimant is refused; the claim is released when the claimant dies",
         %{opts: opts} do
      name = opts[:name]
      start_supervised!(Supervisor.child_spec({Journal, opts}, restart: :temporary))
      parent = self()

      claimant =
        spawn(fn ->
          ExecutorIdentity.assume!(name)
          send(parent, {:claimed, Journal.claim(name)})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:claimed, :ok}
      Process.put(:"$initial_call", {Raxol.Broker.Executor, :init, 1})
      assert Journal.claim(name) == {:error, {:journal_claimed, claimant}}

      ref = Process.monitor(claimant)
      send(claimant, :stop)
      assert_receive {:DOWN, ^ref, :process, ^claimant, _}

      # The claimant is dead, so the claim is free even if the journal has
      # not yet handled its :DOWN.
      assert Journal.claim(name) == :ok
      assert Journal.claim(name) == :ok
    end

    test "with no claim held a plain process can neither claim nor write a group",
         %{opts: opts, path: path} do
      name = opts[:name]
      start_supervised!(Supervisor.child_spec({Journal, opts}, restart: :temporary))
      intent = limit("2")
      ctx = context()
      group = %{intent: intent, context: ctx, entries: placed_entries(intent, ctx)}

      # The claim is free, and still a plain process is refused it.
      assert Journal.claim(name) == {:error, :not_an_executor}
      assert Journal.open_group(intent, ctx, name) == {:error, :unclaimed}
      assert Journal.append_group(group, name) == {:error, :unclaimed}
      assert Journal.append_to_group("any-group", {:placing}, name) == {:error, :unclaimed}
      assert records(path) == []
      assert Journal.open_groups(name) == {:ok, []}
    end

    # The threat-model limit: the journal identifies an Executor by its
    # proc_lib initial call, which a process can forge in its own dictionary.
    # Doing so is deliberate subversion, not a path through the public API.
    test "a process impersonating an Executor can claim and write placing", %{opts: opts} do
      name = opts[:name]
      start_supervised!(Supervisor.child_spec({Journal, opts}, restart: :temporary))
      intent = limit("2")
      ctx = context()

      impostor =
        Task.async(fn ->
          Process.put(:"$initial_call", {Raxol.Broker.Executor, :init, 1})
          :ok = Journal.claim(name)
          {:ok, id} = Journal.open_group(intent, ctx, name)

          placed_entries(intent, ctx)
          |> Enum.take(4)
          |> Enum.map(&Journal.append_to_group(id, &1, name))
        end)

      assert Task.await(impostor) == [:ok, :ok, :ok, :ok]
    end

    test "a float in an order response is recorded as a string and the order counts",
         %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      intent = limit("2")
      ctx = context()
      response = %{"order_id" => "o-1", "avg_price" => 125.01, "legs" => [%{"px" => 1.0e-3}]}

      assert {:ok, _id} =
               Journal.append_group(
                 %{intent: intent, context: ctx, entries: placed_entries(intent, ctx, response)},
                 name
               )

      assert %{"type" => "order", "status" => "placed", "response" => recorded} =
               List.last(records(path))

      assert recorded == %{
               "order_id" => "o-1",
               "avg_price" => "125.01",
               "legs" => [%{"px" => "0.001"}]
             }

      assert counters(name, @t0) == {{:ok, d("250")}, {:ok, 1}}
      assert Journal.verify(name) == :ok
    end

    test "a declined approval finishes the group as DENY, uncounted", %{opts: opts} do
      name = opts[:name]
      start!(opts)
      {:ok, intent} = Intent.limit(:buy, "AAPL", d("2"), d("125"), provenance: :llm)
      ctx = context()
      {:ask, _} = verdict = Policy.evaluate(intent, ctx)
      {:ok, id} = Journal.open_group(intent, ctx, name)

      :ok = Journal.append_to_group(id, {:verdict, :pre_review, verdict}, name)
      :ok = Journal.append_to_group(id, {:approval, :declined, "operator"}, name)

      assert Journal.append_to_group(id, {:placing}, name) ==
               {:error, {:unknown_or_finished_group, id}}

      assert {:error, {:invalid_entry, _}} =
               Journal.append_group(
                 %{intent: intent, context: ctx, entries: [{:approval, :maybe, "operator"}]},
                 name
               )

      assert counters(name, @t0) == {{:ok, d("0")}, {:ok, 0}}
    end
  end

  describe "write timeouts" do
    # A stall is simulated with :sys.suspend; a trace session on
    # GenServer.call/3 shows the deadline each call was made with, so no test
    # waits for a timer to fire.
    setup do
      trace = :trace.session_create(:broker_journal_timeouts, self(), [])
      on_exit(fn -> :trace.session_destroy(trace) end)
      1 = :trace.function(trace, {GenServer, :call, 3}, true, [])
      {:ok, trace: trace}
    end

    # A claimant that writes a reviewed, allowed group and then writes
    # `placing` when told to.
    defp placer(name, intent, ctx) do
      parent = self()

      placer =
        Task.async(fn ->
          ExecutorIdentity.assume!(name)
          {:ok, id} = Journal.open_group(intent, ctx, name)

          placed_entries(intent, ctx)
          |> Enum.take(3)
          |> Enum.each(&(:ok = Journal.append_to_group(id, &1, name)))

          send(parent, {:reviewed, id})
          receive do: (:go -> Journal.append_to_group(id, {:placing}, name))
        end)

      assert_receive {:reviewed, id}
      {placer, id}
    end

    test "placing waits on a stalled journal by default, and lands",
         %{opts: opts, trace: trace} do
      name = opts[:name]
      journal = start_supervised!(Supervisor.child_spec({Journal, opts}, restart: :temporary))
      intent = limit("2")
      {placer, id} = placer(name, intent, context())

      1 = :trace.process(trace, placer.pid, true, [:call])
      :ok = :sys.suspend(journal)
      send(placer.pid, :go)

      # The call is made while the journal is suspended, with no deadline.
      assert_receive {:trace, _, :call,
                      {GenServer, :call, [^name, {:append_to_group, ^id, {:placing}}, :infinity]}}

      :ok = :sys.resume(journal)
      assert Task.await(placer, :infinity) == :ok
      assert {:ok, ^id} = Journal.placing_for_intent(intent.id, name)
    end

    # F3: the Writer stalls (a slow fsync) past the 5 s FileStore default
    # while `placing` is appended. With a deadline on the Writer call the
    # journal would answer `{:writer_down, :timeout}`, the executor would
    # close the group as refused, and the queued `placing` would land later.
    test "placing waits on a stalled Writer, and lands", %{opts: opts, path: path, trace: trace} do
      name = opts[:name]
      journal = start_supervised!(Supervisor.child_spec({Journal, opts}, restart: :temporary))
      {base, session} = Journal.location(path)
      writer = :global.whereis_name({Writer, Path.join(base, session)})
      intent = limit("2")
      {placer, id} = placer(name, intent, context())

      1 = :trace.process(trace, journal, true, [:call])
      :ok = :sys.suspend(writer)
      send(placer.pid, :go)

      # The journal calls its suspended Writer with no deadline.
      assert_receive {:trace, ^journal, :call,
                      {GenServer, :call,
                       [^writer, {:append_many, [%{"type" => "placing"}]}, :infinity]}}

      :ok = :sys.resume(writer)
      assert Task.await(placer, :infinity) == :ok
      assert {:ok, ^id} = Journal.placing_for_intent(intent.id, name)
      assert {:ok, [^id]} = Journal.open_groups(name)
      assert %{"type" => "placing", "group_id" => ^id} = List.last(records(path))
    end

    test "a caller-supplied timeout bounds the call, and the queued write still lands",
         %{opts: opts, path: path} do
      name = opts[:name]
      journal = start!(opts)
      {:ok, id} = Journal.open_group(limit("2"), context(), name)
      before = length(records(path))

      :ok = :sys.suspend(journal)
      assert {:timeout, _} = catch_exit(Journal.append_to_group(id, {:review, %{}}, name, 0))
      :ok = :sys.resume(journal)

      # This is why the default is :infinity: the caller gave up, but the
      # journal still wrote the record once it ran.
      assert {:ok, [^id]} = Journal.open_groups(name)
      assert length(records(path)) == before + 1
    end
  end

  describe "index" do
    test "only placed orders count; denials, failed orders and cancels never do",
         %{opts: opts, clock: clock} do
      start!(opts)
      name = opts[:name]
      ctx = context()

      at(clock, @t0)

      {:ok, _} =
        Journal.append_group(
          %{intent: limit("2"), context: ctx, entries: placed_entries(limit("2"), ctx)},
          name
        )

      big = limit("100")

      {:ok, _} =
        Journal.append_group(
          %{
            intent: big,
            context: ctx,
            entries: [{:verdict, :pre_review, Policy.evaluate(big, ctx)}]
          },
          name
        )

      failed = limit("3")

      entries =
        List.replace_at(
          placed_entries(failed, ctx),
          -1,
          {:order, :failed, %{"error" => "rejected"}}
        )

      {:ok, _} = Journal.append_group(%{intent: failed, context: ctx, entries: entries}, name)

      {:ok, cancel} = Intent.cancel("o-1", provenance: :human)

      {:ok, _} =
        Journal.append_group(
          %{intent: cancel, context: ctx, entries: placed_entries(cancel, ctx)},
          name
        )

      at(clock, DateTime.add(@t0, 30, :second))
      second = limit("1", "100")

      {:ok, _} =
        Journal.append_group(
          %{intent: second, context: ctx, entries: placed_entries(second, ctx)},
          name
        )

      assert Journal.today_notional(@day, name) == {:ok, d("350")}
      # `since` is inclusive.
      assert Journal.today_notional(@t0, name) == {:ok, d("350")}
      assert Journal.today_notional(DateTime.add(@t0, 1, :second), name) == {:ok, d("100")}

      # The minute window excludes its start and includes `now`.
      assert Journal.orders_last_minute(DateTime.add(@t0, 59, :second), name) == {:ok, 2}
      assert Journal.orders_last_minute(DateTime.add(@t0, 60, :second), name) == {:ok, 1}
      assert Journal.orders_last_minute(DateTime.add(@t0, 90, :second), name) == {:ok, 0}
    end

    test "the index is rebuilt from disk on start", %{opts: opts, clock: clock} do
      name = opts[:name]
      start!(opts)
      ctx = context()

      {:ok, _} =
        Journal.append_group(
          %{intent: limit("2"), context: ctx, entries: placed_entries(limit("2"), ctx)},
          name
        )

      fill = %{
        order_id: "o-1",
        symbol: "AAPL",
        side: :sell,
        qty: d("2"),
        price: d("130"),
        realized_pnl: d("-12.50")
      }

      assert :ok = Journal.append_fill(fill, name)
      at(clock, DateTime.add(@t0, 5, :second))
      assert :ok = Journal.append_fill(%{fill | realized_pnl: d("30")}, name)
      assert {:error, {:invalid_fill, _}} = Journal.append_fill(%{fill | realized_pnl: 1.5}, name)

      stop_supervised!(name)
      start!(opts)

      assert Journal.status(name) == :ok
      assert Journal.today_notional(@day, name) == {:ok, d("250")}
      assert Journal.realized_pnl_today(@day, name) == {:ok, d("17.50")}
      assert Journal.realized_pnl_today(DateTime.add(@t0, 1, :second), name) == {:ok, d("30")}
    end
  end

  describe "crash recovery" do
    test "killing the writer between intent and verdict closes the group as DENY, uncounted",
         %{opts: opts, path: path} do
      name = opts[:name]
      journal = start!(opts)
      ctx = context()

      {:ok, _} =
        Journal.append_group(
          %{intent: limit("2"), context: ctx, entries: placed_entries(limit("2"), ctx)},
          name
        )

      {:ok, crashed} = Journal.open_group(limit("4"), ctx, name)

      kill_writer!(path, journal)

      # Read-side, before any restart: the open group already renders as DENY.
      assert {:ok, lines} = Replay.run(path, ~D[2026-10-02])
      assert Enum.any?(lines, &(&1 =~ "outcome  DENY crash_before_verdict (open on disk"))

      start!(opts)
      assert Journal.status(name) == :ok

      close = List.last(records(path))

      assert %{
               "type" => "close",
               "group_id" => ^crashed,
               "reason" => "crash_before_verdict",
               "outcome" => "deny"
             } = close

      assert Journal.today_notional(@day, name) == {:ok, d("250")}
      assert Journal.orders_last_minute(@t0, name) == {:ok, 1}

      assert {:ok, lines} = Replay.run(path, ~D[2026-10-02])
      assert Enum.count(lines, &(&1 =~ "outcome  DENY crash_before_verdict")) == 1

      assert Journal.append_to_group(crashed, {:review, %{}}, name) ==
               {:error, {:unknown_or_finished_group, crashed}}
    end

    test "a crash after the post-review ALLOW but before placing is a DENY, uncounted",
         %{opts: opts, path: path} do
      name = opts[:name]
      journal = start!(opts)
      intent = limit("4")
      ctx = context()
      id = in_flight!(name, limit("2"), ctx)
      :ok = Journal.append_to_group(id, {:order, :placed, %{}}, name)

      {:ok, crashed} = Journal.open_group(intent, ctx, name)

      placed_entries(intent, ctx)
      |> Enum.take(3)
      |> Enum.each(&(:ok = Journal.append_to_group(crashed, &1, name)))

      kill_writer!(path, journal)
      start!(opts)

      assert %{
               "group_id" => ^crashed,
               "reason" => "crash_before_verdict",
               "outcome" => "deny"
             } = List.last(records(path))

      assert counters(name, @t0) == {{:ok, d("250")}, {:ok, 1}}
    end

    test "an approved ASK placed and then crashed is an unknown outcome, counted at placing",
         %{opts: opts, path: path, clock: clock} do
      name = opts[:name]
      journal = start!(opts)
      {:ok, intent} = Intent.limit(:buy, "AAPL", d("4"), d("125"), provenance: :llm)
      ctx = context()
      {:ask, _} = verdict = Policy.evaluate(intent, ctx)

      {:ok, id} = Journal.open_group(intent, ctx, name)
      :ok = Journal.append_to_group(id, {:verdict, :pre_review, verdict}, name)
      :ok = Journal.append_to_group(id, {:review, %{"warnings" => []}}, name)
      :ok = Journal.append_to_group(id, {:verdict, :post_review, verdict}, name)
      :ok = Journal.append_to_group(id, {:approval, :approved, "operator"}, name)
      at(clock, DateTime.add(@t0, 10, :second))
      :ok = Journal.append_to_group(id, {:placing}, name)

      placed_at = DateTime.add(@t0, 10, :second)
      live = counters(name, placed_at)
      assert live == {{:ok, d("500")}, {:ok, 1}}

      kill_writer!(path, journal)
      at(clock, ~U[2026-10-03 09:00:00Z])
      start!(opts)

      assert %{
               "group_id" => ^id,
               "reason" => "crash_outcome_unknown",
               "outcome" => "unknown"
             } = List.last(records(path))

      # Counted at the placing record, not at the restart a day later.
      assert counters(name, placed_at) == live
      assert Journal.today_notional(~U[2026-10-03 00:00:00Z], name) == {:ok, d("0")}
    end
  end

  describe "counting from placing" do
    test "an in-flight order counts live and after a restart alike", %{opts: opts, clock: clock} do
      name = opts[:name]
      start!(opts)
      placed_at = DateTime.add(@t0, 5, :second)
      at(clock, placed_at)
      in_flight!(name, limit("4"), context())

      live = counters(name, placed_at)
      assert live == {{:ok, d("500")}, {:ok, 1}}
      assert Journal.orders_last_minute(DateTime.add(placed_at, 60, :second), name) == {:ok, 0}

      stop_supervised!(name)
      start!(opts)

      assert Journal.status(name) == :ok
      assert counters(name, placed_at) == live
    end

    test "a failed order stops counting, live and after a restart", %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      id = in_flight!(name, limit("4"), context())
      assert counters(name, @t0) == {{:ok, d("500")}, {:ok, 1}}

      :ok = Journal.append_to_group(id, {:order, :failed, %{"error" => "rejected"}}, name)
      assert counters(name, @t0) == {{:ok, d("0")}, {:ok, 0}}

      stop_supervised!(name)
      start!(opts)

      assert counters(name, @t0) == {{:ok, d("0")}, {:ok, 0}}
      assert %{"type" => "order", "status" => "failed"} = List.last(records(path))
    end

    test "an unknown order response keeps counting", %{opts: opts} do
      name = opts[:name]
      start!(opts)
      id = in_flight!(name, limit("4"), context())
      :ok = Journal.append_to_group(id, {:order, :unknown, %{"error" => "timeout"}}, name)
      assert counters(name, @t0) == {{:ok, d("500")}, {:ok, 1}}

      stop_supervised!(name)
      start!(opts)
      assert counters(name, @t0) == {{:ok, d("500")}, {:ok, 1}}
    end

    test "a close after placing is an unknown outcome and keeps counting",
         %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      id = in_flight!(name, limit("4"), context())
      :ok = Journal.append_to_group(id, {:close, :abandoned}, name)

      assert %{"type" => "close", "reason" => "abandoned", "outcome" => "unknown"} =
               List.last(records(path))

      assert counters(name, @t0) == {{:ok, d("500")}, {:ok, 1}}
      written = length(records(path))

      stop_supervised!(name)
      start!(opts)

      assert counters(name, @t0) == {{:ok, d("500")}, {:ok, 1}}
      assert length(records(path)) == written
    end

    test "a close before placing is a DENY", %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      {:ok, id} = Journal.open_group(limit("4"), context(), name)
      :ok = Journal.append_to_group(id, {:close, :abandoned}, name)

      assert %{"type" => "close", "outcome" => "deny"} = List.last(records(path))
      assert counters(name, @t0) == {{:ok, d("0")}, {:ok, 0}}
    end
  end

  describe "lifecycle" do
    test "a supervisor shutdown stops the Writer the journal started", %{opts: opts, path: path} do
      start!(opts)
      {base, session} = Journal.location(path)
      writer = :global.whereis_name({Writer, Path.join(base, session)})
      ref = Process.monitor(writer)

      stop_supervised!(opts[:name])
      assert_receive {:DOWN, ^ref, :process, ^writer, _reason}
    end

    test "a journal that joined a running Writer stops when that Writer dies",
         %{opts: opts, path: path} do
      {base, session} = Journal.location(path)
      {:ok, handle} = FileStore.open(session, base_dir: base, chain: true)
      Process.unlink(handle.writer)

      journal = start!(opts)
      assert Journal.status(opts[:name]) == :ok

      kill_writer!(path, journal)
    end
  end

  describe "damage" do
    test "a flipped byte on disk refuses every append and query, and replay", %{
      opts: opts,
      path: path
    } do
      name = opts[:name]
      start!(opts)
      ctx = context()

      {:ok, _} =
        Journal.append_group(
          %{intent: limit("2"), context: ctx, entries: placed_entries(limit("2"), ctx)},
          name
        )

      stop_supervised!(name)

      [segment] = Path.wildcard(Path.join(path, "journal/*.jsonl"))
      bytes = File.read!(segment)
      [first, second, third | _] = String.split(bytes, "\n")
      # A byte in the middle of record 3 (the pre-review verdict).
      at = byte_size(first) + 1 + byte_size(second) + 1 + div(byte_size(third), 2)
      <<pre::binary-size(^at), byte, post::binary>> = bytes
      File.write!(segment, <<pre::binary, Bitwise.bxor(byte, 1), post::binary>>)

      start!(opts)
      assert Journal.status(name) == {:damaged, 3}
      assert Journal.verify(name) == {:broken, 3}
      assert Journal.open_group(limit("1"), ctx, name) == {:error, {:journal_damaged, 3}}
      assert Journal.today_notional(@day, name) == {:error, {:journal_damaged, 3}}
      assert Journal.orders_last_minute(@t0, name) == {:error, {:journal_damaged, 3}}
      assert Replay.run(path, ~D[2026-10-02]) == {:error, {:broken, 3}}
      assert File.read!(segment) == <<pre::binary, Bitwise.bxor(byte, 1), post::binary>>
    end

    test "verify/1 on a running journal catches a change made underneath it", %{
      opts: opts,
      path: path
    } do
      name = opts[:name]
      start!(opts)
      ctx = context()

      {:ok, _} =
        Journal.append_group(
          %{intent: limit("2"), context: ctx, entries: placed_entries(limit("2"), ctx)},
          name
        )

      [segment] = Path.wildcard(Path.join(path, "journal/*.jsonl"))

      File.write!(
        segment,
        String.replace(File.read!(segment), ~s("qty":"2"), ~s("qty":"9"), global: false)
      )

      assert Journal.verify(name) == {:broken, 1}
      assert Journal.today_notional(@day, name) == {:error, {:journal_damaged, 1}}
      assert Journal.open_group(limit("1"), ctx, name) == {:error, {:journal_damaged, 1}}
    end

    test "verify/1 on a journal whose chain flag was removed reports it and refuses it", %{
      opts: opts,
      path: path
    } do
      name = opts[:name]
      journal = start!(opts)
      ctx = context()

      {:ok, _} =
        Journal.append_group(
          %{intent: limit("2"), context: ctx, entries: placed_entries(limit("2"), ctx)},
          name
        )

      meta = Path.join(path, "meta.json")

      File.write!(
        meta,
        meta |> File.read!() |> Jason.decode!() |> Map.delete("chain") |> Jason.encode!()
      )

      refute Journal.verify(name) == :ok
      assert Process.alive?(journal)
      refute Journal.status(name) == :ok
      assert {:error, _} = Journal.open_group(limit("1"), ctx, name)
      assert {:error, _} = Journal.today_notional(@day, name)
    end
  end

  describe "codec" do
    test "intents and contexts round-trip through their JSON form" do
      {:ok, option} =
        Intent.option(:buy, "AAPL", d("1500.00"),
          provenance: {:untrusted, :web},
          strategy: :momentum,
          params: %{"legs" => [%{"strike" => "190"}]}
        )

      {:ok, sell} =
        Intent.sell("BRK.B", d("0.5"), provenance: {:untrusted, "email"}, strategy: "mean")

      {:ok, cancel} = Intent.cancel("o-1", provenance: :human, id: "fixed")

      for intent <- [option, sell, cancel, limit("2")] do
        json = intent |> Codec.encode_intent() |> Jason.encode!() |> Jason.decode!()
        assert Codec.decode_intent(json) == {:ok, intent}
      end

      ctx =
        context(
          positions: %{"AAPL" => d("1E+3")},
          review_warnings: ["thin market"],
          market_session: nil
        )

      json = ctx |> Codec.encode_context() |> Jason.encode!() |> Jason.decode!()
      assert Codec.decode_context(json) == {:ok, ctx}
    end

    test "floats in opaque terms become their shortest decimal strings" do
      assert Codec.term(%{"px" => 125.01, "qty" => 2, "fees" => [0.1, -3.0e-7]}) ==
               %{"px" => "125.01", "qty" => 2, "fees" => ["0.1", "-3.0e-7"]}
    end
  end
end
