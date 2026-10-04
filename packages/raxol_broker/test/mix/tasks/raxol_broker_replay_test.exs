defmodule Mix.Tasks.Raxol.Broker.ReplayTest do
  use ExUnit.Case, async: false

  alias Raxol.Broker.{Intent, Journal, Policy, PolicyFile}
  alias Raxol.Broker.Policy.Context

  @moduletag :capture_log
  @t0 ~U[2026-10-02 14:30:00.000000Z]

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    base = Path.join(System.tmp_dir!(), "broker-replay-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    on_exit(fn ->
      Mix.shell(previous_shell)
      File.rm_rf!(base)
    end)

    {:ok, clock} = Agent.start_link(fn -> @t0 end)
    name = :"broker_replay_#{System.unique_integer([:positive])}"
    path = Path.join(base, "journal")
    opts = [name: name, path: path, clock: fn -> Agent.get(clock, & &1) end]
    {:ok, opts: opts, name: name, path: path, clock: clock}
  end

  defp d(value), do: Decimal.new(value)

  defp context do
    {:ok, policy} = PolicyFile.new(d("1000"), d("5000"))

    %Context{
      policy: policy,
      portfolio_value: d("100000"),
      start_of_day_value: d("100000"),
      day_pnl: d("0"),
      quotes: %{"AAPL" => d("125")},
      today_notional: d("0"),
      orders_last_minute: 0,
      market_session: :regular
    }
  end

  defp limit(qty) do
    {:ok, intent} = Intent.limit(:buy, "AAPL", d(qty), d("125"), provenance: :strategy)
    intent
  end

  defp output do
    receive do
      {:mix_shell, :info, [line]} -> [line | output()]
    after
      0 -> []
    end
  end

  test "prints each group's intent, per-rule verdicts, review, order and outcome in journal order",
       %{opts: opts, name: name, path: path, clock: clock} do
    start_supervised!({Journal, opts})
    ctx = context()

    placed = limit("2")
    {:allow, _} = allow = Policy.evaluate(placed, ctx)

    {:ok, placed_id} =
      Journal.append_group(
        %{
          intent: placed,
          context: ctx,
          entries: [
            {:verdict, :pre_review, allow},
            {:review, %{"warnings" => []}},
            {:verdict, :post_review, allow},
            {:placing},
            {:order, :placed, %{"order_id" => "rh-1"}}
          ]
        },
        name
      )

    denied = limit("100")

    {:ok, denied_id} =
      Journal.append_group(
        %{
          intent: denied,
          context: ctx,
          entries: [{:verdict, :pre_review, Policy.evaluate(denied, ctx)}]
        },
        name
      )

    # Another day: never printed for 2026-10-02.
    Agent.update(clock, fn _ -> ~U[2026-10-03 10:00:00Z] end)
    {:ok, _} = Journal.open_group(limit("1"), ctx, name)

    Mix.Tasks.Raxol.Broker.Replay.run(["--date", "2026-10-02", "--journal", path])
    lines = output()

    assert hd(lines) == "broker journal 2026-10-02 (UTC): 2 group(s), 0 fill(s)"

    placed_at =
      Enum.find_index(lines, &(&1 == "group #{placed_id} opened 2026-10-02T14:30:00.000000Z"))

    denied_at =
      Enum.find_index(lines, &(&1 == "group #{denied_id} opened 2026-10-02T14:30:00.000000Z"))

    assert placed_at < denied_at

    placed_lines = Enum.slice(lines, placed_at..(denied_at - 1))

    assert Enum.at(placed_lines, 1) =~
             ~r/^  intent   limit buy AAPL qty=2 limit=125 provenance="strategy" id=/

    assert Enum.at(placed_lines, 2) =~
             "today_notional=0 orders_last_minute=0 market_session=regular"

    assert "  verdict  pre_review ALLOW" in placed_lines
    assert "    max_notional_per_order   allow" in placed_lines
    assert ~s(  review   {"warnings":[]}) in placed_lines
    assert "  placing  notional=250" in placed_lines
    assert ~s(  order    placed {"order_id":"rh-1"}) in placed_lines
    assert List.last(placed_lines) == ""
    assert Enum.at(placed_lines, -2) == "  outcome  PLACED"

    denied_lines = Enum.drop(lines, denied_at)
    assert "  verdict  pre_review DENY" in denied_lines
    assert "    order_rate               pass" in denied_lines
    assert ~s(    max_notional_per_order   DENY {"cap":"1000","notional":"12500"}) in denied_lines
    assert "    daily_notional_cap       not run" in denied_lines
    assert List.last(denied_lines) == "  outcome  DENY max_notional_per_order"
    refute Enum.any?(lines, &(&1 =~ "2026-10-03"))
  end

  test "refuses a damaged journal and names the broken offset", %{
    opts: opts,
    name: name,
    path: path
  } do
    start_supervised!({Journal, opts})
    {:ok, _} = Journal.open_group(limit("2"), context(), name)
    stop_supervised!(name)

    [segment] = Path.wildcard(Path.join(path, "journal/*.jsonl"))

    File.write!(
      segment,
      String.replace(File.read!(segment), ~s("symbol":"AAPL"), ~s("symbol":"AAPM"))
    )

    assert_raise Mix.Error, ~r/hash chain broken at offset 1/, fn ->
      Mix.Tasks.Raxol.Broker.Replay.run(["--date", "2026-10-02", "--journal", path])
    end
  end

  test "requires a valid date and an existing journal", %{path: path} do
    assert_raise Mix.Error, ~r/usage/, fn ->
      Mix.Tasks.Raxol.Broker.Replay.run(["--journal", path])
    end

    assert_raise Mix.Error, ~r/YYYY-MM-DD/, fn ->
      Mix.Tasks.Raxol.Broker.Replay.run(["--date", "10/02/2026", "--journal", path])
    end

    assert_raise Mix.Error, ~r/no broker journal/, fn ->
      Mix.Tasks.Raxol.Broker.Replay.run(["--date", "2026-10-02", "--journal", path])
    end
  end
end
