defmodule Raxol.Broker.Journal.ReplayTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Broker.Journal.Replay

  @date ~D[2026-10-02]
  @at "2026-10-02T14:30:00.000000Z"

  setup do
    base =
      Path.join(System.tmp_dir!(), "broker-replay-unit-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, path: Path.join(base, "journal")}
  end

  # Writes raw broker records through a chained FileStore, the way the
  # broker journal does, and renders them with the task's read path.
  defp replay(path, records) do
    {:ok, handle} =
      FileStore.open(Path.basename(path), base_dir: Path.dirname(path), chain: true)

    {:ok, _} = FileStore.append_many(handle, records)
    :ok = FileStore.close(handle)
    {:ok, lines} = Replay.run(path, @date)
    lines
  end

  defp rec(group, type, fields),
    do: Map.merge(%{"kind" => "broker", "group_id" => group, "at" => @at, "type" => type}, fields)

  defp intent(group, overrides \\ %{}) do
    rec(group, "intent", %{
      "intent" =>
        Map.merge(
          %{
            "kind" => "limit",
            "side" => "buy",
            "symbol" => "AAPL",
            "qty" => "2",
            "limit" => "125",
            "provenance" => "strategy",
            "id" => "intent-#{group}"
          },
          overrides
        )
    })
  end

  defp context(group) do
    rec(group, "context", %{
      "context" => %{
        "today_notional" => "0",
        "orders_last_minute" => 0,
        "market_session" => "regular"
      }
    })
  end

  defp group_lines(lines, group) do
    lines
    |> Enum.drop_while(&(not String.starts_with?(&1, "group #{group} ")))
    |> Enum.take_while(&(&1 != ""))
  end

  defp outcome(lines, group),
    do: lines |> group_lines(group) |> List.last()

  test "no rendered line carries a C0, DEL or C1 control byte", %{path: path} do
    hostile = "x\e]52;c;cm0gLXJmIC8=\a\e[2J\x7F\u009Bdone"

    lines =
      replay(path, [
        intent("g1", %{"id" => hostile, "strategy" => hostile, "order_id" => hostile}),
        context("g1"),
        rec("g1", "close", %{"reason" => hostile, "outcome" => "deny"}),
        rec("f", "fill", %{
          "fill" => %{"side" => "buy", "symbol" => "AAPL", "order_id" => hostile}
        })
      ])

    for line <- lines do
      for <<byte <- line>>, do: refute(byte < 0x20 or byte == 0x7F, inspect(line))
      for <<c::utf8 <- line>>, do: refute(c in 0x80..0x9F, inspect(line))
    end

    [intent_line] = Enum.filter(lines, &String.starts_with?(&1, "  intent"))
    assert intent_line =~ ~S(id=x\u001b]52;c;cm0gLXJmIC8=\u0007\u001b[2J\u007f\u009bdone)
    assert intent_line =~ ~S(strategy=x\u001b])
    assert Enum.any?(lines, &(&1 =~ ~S(order_id=x\u001b])))
  end

  test "escape/1 handles invalid UTF-8 without crashing" do
    assert Replay.escape(<<"a", 0xFF, 0xC2, "b\n">>) == ~S(a\xff\xc2b\u000a)
    assert Replay.escape("ünïcode ok") == "ünïcode ok"
  end

  test "renders approval, placing and order status unknown", %{path: path} do
    lines =
      replay(path, [
        intent("g1"),
        context("g1"),
        rec("g1", "approval", %{"decision" => "approved", "by" => "operator"}),
        rec("g1", "placing", %{"notional" => "250"}),
        rec("g1", "order", %{"status" => "unknown", "response" => %{"error" => "timeout"}})
      ])

    group = group_lines(lines, "g1")
    assert "  approval approved by operator" in group
    assert "  placing  notional=250" in group
    assert ~s(  order    unknown {"error":"timeout"}) in group
    assert List.last(group) == "  outcome  UNKNOWN (counted)"
  end

  test "declined approval is a deny; a cancel placing renders as cancel", %{path: path} do
    lines =
      replay(path, [
        intent("g1"),
        context("g1"),
        rec("g1", "approval", %{"decision" => "declined", "by" => "operator"}),
        rec("g1", "close", %{"reason" => "declined", "outcome" => "deny"}),
        intent("g2", %{"kind" => "cancel", "order_id" => "rh-1"}),
        context("g2"),
        rec("g2", "placing", %{"notional" => nil}),
        rec("g2", "order", %{"status" => "placed", "response" => %{}})
      ])

    assert "  approval declined by operator" in group_lines(lines, "g1")
    assert outcome(lines, "g1") == "  outcome  DENY declined"
    assert "  placing  cancel" in group_lines(lines, "g2")
    assert outcome(lines, "g2") == "  outcome  PLACED"
  end

  test "an abandoned send closes unknown and counts", %{path: path} do
    lines =
      replay(path, [
        intent("g1"),
        context("g1"),
        rec("g1", "placing", %{"notional" => "250"}),
        rec("g1", "close", %{"reason" => "caller_down", "outcome" => "unknown"})
      ])

    assert "  close    caller_down (unknown)" in group_lines(lines, "g1")
    assert outcome(lines, "g1") == "  outcome  UNKNOWN caller_down (counted)"
  end

  test "a group open on disk with a placing record is in flight", %{path: path} do
    lines =
      replay(path, [
        intent("g1"),
        context("g1"),
        rec("g1", "placing", %{"notional" => "250"}),
        intent("g2"),
        context("g2")
      ])

    assert outcome(lines, "g1") ==
             "  outcome  IN FLIGHT (counted) " <>
               "(open on disk; closed at next start as UNKNOWN crash_outcome_unknown)"

    assert outcome(lines, "g2") ==
             "  outcome  DENY crash_before_verdict (open on disk; closed at next start)"
  end
end
