defmodule Raxol.Broker.JournalTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.FileStore.Writer
  alias Raxol.Broker.{Intent, Journal, Policy, PolicyFile}
  alias Raxol.Broker.Journal.{Codec, Replay}
  alias Raxol.Broker.Policy.Context

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

  defp start!(opts) do
    start_supervised!(Supervisor.child_spec({Journal, opts}, restart: :temporary))
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

  # The full happy path: both policy passes allow and the order is placed.
  defp placed_entries(intent, context) do
    {:allow, _} = verdict = Policy.evaluate(intent, context)

    [
      {:verdict, :pre_review, verdict},
      {:review, %{"warnings" => []}},
      {:verdict, :post_review, verdict},
      {:order, :placed, %{"order_id" => "o-#{intent.id}"}}
    ]
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
    assert_receive {:DOWN, ^ref, :process, ^journal, :killed}
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
      assert Enum.map(records, & &1["type"]) == ~w(intent context verdict review verdict order)
      assert Enum.all?(records, &(&1["group_id"] == id))
      assert Enum.map(records, & &1["id"]) == Enum.to_list(1..6)

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

    test "a crash after the post-review ALLOW is an unknown outcome and counts",
         %{opts: opts, path: path, clock: clock} do
      name = opts[:name]
      journal = start!(opts)
      intent = limit("4")
      ctx = context()
      {:allow, _} = verdict = Policy.evaluate(intent, ctx)

      {:ok, id} = Journal.open_group(intent, ctx, name)
      :ok = Journal.append_to_group(id, {:verdict, :pre_review, verdict}, name)
      :ok = Journal.append_to_group(id, {:review, %{"warnings" => []}}, name)
      at(clock, DateTime.add(@t0, 10, :second))
      :ok = Journal.append_to_group(id, {:verdict, :post_review, verdict}, name)

      kill_writer!(path, journal)
      at(clock, ~U[2026-10-03 09:00:00Z])
      start!(opts)

      assert %{"reason" => "crash_outcome_unknown", "outcome" => "unknown"} =
               List.last(records(path))

      # Counted at the post-review ALLOW, not at the restart a day later.
      assert Journal.today_notional(@day, name) == {:ok, d("500")}
      assert Journal.orders_last_minute(DateTime.add(@t0, 10, :second), name) == {:ok, 1}
      assert Journal.today_notional(~U[2026-10-03 00:00:00Z], name) == {:ok, d("0")}
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
  end
end
