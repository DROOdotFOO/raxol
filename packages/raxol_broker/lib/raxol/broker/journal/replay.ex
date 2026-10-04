defmodule Raxol.Broker.Journal.Replay do
  @moduledoc """
  Renders the broker journal's decision trace for one UTC day: each group
  opened that day, in journal order, as intent, context, every rule's verdict
  for each policy pass, review, order, and outcome. Fills recorded that day
  follow.

  Reading never writes: the journal is read through
  `Raxol.Agent.Journal.FileStore.verify_session/2` and `read_records/2`, so it
  works while the broker runs in another process. A chain that does not
  verify is refused, not rendered.

  Per-rule lines come from the verdict as recorded and the rule ids stored
  with it. The policy stops at the first DENY, so rules before the denying
  one are shown as `pass` (they allowed or asked) and rules after it as
  `not run`. A group still open on disk (the broker stopped and has not
  restarted since) is shown the way the next start will close it.
  """

  alias Raxol.Agent.Journal.Chain
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Broker.Journal
  alias Raxol.Broker.Journal.Groups

  @doc """
  Load and render the journal at `path` for `date`. `{:error, reason}` when
  there is no journal there or its chain is broken.
  """
  @spec run(Path.t(), Date.t()) :: {:ok, [String.t()]} | {:error, term()}
  def run(path, %Date{} = date) do
    {base, session} = Journal.location(path)

    with true <- File.dir?(Path.join(base, session)) || {:error, {:no_journal, path}},
         :ok <- verified(FileStore.verify_session(session, base_dir: base)),
         {:ok, records} <- FileStore.read_records(session, base_dir: base) do
      {:ok, render(records, date)}
    end
  end

  defp verified(:ok), do: :ok
  defp verified({:broken, offset}), do: {:error, {:broken, offset}}
  defp verified({:error, :unchained}), do: {:error, :unchained}

  @doc "Render decoded journal records for `date` (UTC) as text lines."
  @spec render([map()], Date.t()) :: [String.t()]
  def render(records, %Date{} = date) do
    {groups, fills} = Groups.fold(records)
    groups = Enum.filter(groups, &on?(&1.opened_at, date))
    fills = Enum.filter(fills, &on?(&1["at"], date))

    header =
      "broker journal #{Date.to_iso8601(date)} (UTC): #{length(groups)} group(s), #{length(fills)} fill(s)"

    [header | Enum.flat_map(groups, &group_lines/1) ++ Enum.map(fills, &fill_line/1)]
  end

  defp on?(at, date) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> DateTime.to_date(datetime) == date
      _ -> false
    end
  end

  defp on?(_at, _date), do: false

  defp group_lines(group) do
    Enum.concat([
      ["", "group #{group.id} opened #{group.opened_at}"],
      Enum.flat_map(group.records, &record_lines/1),
      ["  outcome  #{outcome(group)}"]
    ])
  end

  defp record_lines(%{"type" => "intent", "intent" => intent}),
    do: ["  intent   " <> intent_line(intent)]

  defp record_lines(%{"type" => "context", "context" => context}),
    do: ["  context  " <> context_line(context)]

  defp record_lines(%{"type" => "verdict"} = record) do
    result = record["result"]

    ["  verdict  #{record["phase"]} #{String.upcase(result["action"])}"] ++
      rule_lines(result, record["rule_ids"])
  end

  defp record_lines(%{"type" => "review", "response" => response}),
    do: ["  review   " <> json(response)]

  defp record_lines(%{"type" => "order"} = record),
    do: ["  order    #{record["status"]} #{json(record["response"])}"]

  defp record_lines(%{"type" => "close"} = record),
    do: ["  close    #{record["reason"]} (#{record["outcome"]})"]

  defp record_lines(record), do: ["  record   " <> json(record)]

  defp rule_lines(%{"action" => "allow"}, rule_ids),
    do: Enum.map(rule_ids, &rule_line(&1, "allow"))

  defp rule_lines(%{"action" => "ask", "asks" => asks}, rule_ids) do
    prompts = Map.new(asks, &{&1["rule"], &1["prompt"]})

    Enum.map(rule_ids, fn rule ->
      case Map.fetch(prompts, rule) do
        {:ok, prompt} -> rule_line(rule, "ASK " <> prompt)
        :error -> rule_line(rule, "allow")
      end
    end)
  end

  defp rule_lines(%{"action" => "deny", "rule" => denier, "detail" => detail}, rule_ids) do
    deny = rule_line(denier, "DENY " <> json(detail))

    case Enum.split_while(rule_ids, &(&1 != denier)) do
      {before, [_denier | rest]} ->
        Enum.concat([Enum.map(before, &rule_line(&1, "pass")), [deny], not_run(rest)])

      # `:policy_file` and `:context` deny before any rule runs.
      {_all, []} ->
        [deny | not_run(rule_ids)]
    end
  end

  defp not_run(rules), do: Enum.map(rules, &rule_line(&1, "not run"))

  defp rule_line(rule, text), do: "    #{String.pad_trailing(rule, 24)} #{text}"

  defp outcome(group) do
    case Groups.outcome(group) do
      :placed -> "PLACED"
      :failed -> "FAILED"
      :unknown -> "UNKNOWN #{group.close["reason"]} (counted)"
      :denied -> "DENY" <> deny_reason(group)
      :open -> open_outcome(group)
    end
  end

  defp deny_reason(%{close: %{"reason" => reason}}), do: " " <> reason

  defp deny_reason(group) do
    case Groups.last_verdict(group) do
      %{"result" => %{"rule" => rule}} -> " " <> rule
      _ -> ""
    end
  end

  defp open_outcome(group) do
    case Groups.crash_close(group) do
      {reason, "deny"} -> "DENY #{reason} (open on disk; closed at next start)"
      {reason, "unknown"} -> "UNKNOWN #{reason} (open on disk; closed at next start, counted)"
    end
  end

  defp intent_line(intent) do
    [
      intent["kind"],
      intent["side"],
      intent["symbol"],
      field(intent, "qty"),
      field(intent, "notional"),
      field(intent, "limit"),
      field(intent, "stop"),
      field(intent, "order_id"),
      "provenance=" <> json(intent["provenance"]),
      field(intent, "strategy"),
      "id=" <> intent["id"]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp context_line(context) do
    [
      field(context, "today_notional"),
      field(context, "orders_last_minute"),
      field(context, "market_session"),
      field(context, "portfolio_value"),
      field(context, "day_pnl"),
      "review_warnings=#{length(List.wrap(context["review_warnings"]))}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp field(map, key) do
    case map[key] do
      nil -> nil
      value when is_binary(value) -> "#{key}=#{value}"
      value -> "#{key}=#{json(value)}"
    end
  end

  defp fill_line(%{"fill" => fill, "at" => at}) do
    "fill #{at} #{fill["side"]} #{fill["symbol"]} qty=#{fill["qty"]} price=#{fill["price"]} " <>
      "realized_pnl=#{fill["realized_pnl"]} order_id=#{fill["order_id"]}"
  end

  defp json(value), do: value |> Chain.canonical() |> IO.iodata_to_binary()
end
