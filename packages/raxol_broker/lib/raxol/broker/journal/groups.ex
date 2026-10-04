defmodule Raxol.Broker.Journal.Groups do
  @moduledoc """
  Folds broker journal records into decision groups. Pure: shared by
  `Raxol.Broker.Journal` (crash recovery and the ETS index) and the replay
  renderer, so both read a journal the same way.

  A group is the records sharing one `group_id`: intent, context snapshot,
  verdicts (`pre_review`, then `post_review`), review responses, and one
  terminal record. Its outcome:

  | Outcome | When |
  | --- | --- |
  | `:placed` | an `order` record with status `placed` |
  | `:failed` | an `order` record with status `failed` |
  | `:denied` | a DENY verdict, or a `close` record with outcome `deny` |
  | `:unknown` | a `close` record with outcome `unknown`: the broker stopped after a post-review ALLOW and before the order response, so an order may exist |
  | `:open` | none of the above yet |

  Only `:placed` and `:unknown` groups count toward notional and order rate,
  and never cancels.
  """

  defstruct [:id, :opened_at, :intent, :context, :order, :close, records: [], verdicts: []]

  @type t :: %__MODULE__{
          id: String.t(),
          opened_at: String.t() | nil,
          intent: map() | nil,
          context: map() | nil,
          order: map() | nil,
          close: map() | nil,
          records: [map()],
          verdicts: [map()]
        }

  @type outcome :: :open | :denied | :placed | :failed | :unknown

  @doc """
  Fold journal records, in offset order, into `{groups, fills}`. Groups are in
  the order they were opened; records that are not broker records are skipped.
  """
  @spec fold([map()]) :: {[t()], [map()]}
  def fold(records) do
    {order, groups, fills} = Enum.reduce(records, {[], %{}, []}, &collect/2)
    groups = order |> Enum.reverse() |> Enum.map(&finish(Map.fetch!(groups, &1)))
    {groups, Enum.reverse(fills)}
  end

  defp collect(%{"kind" => "broker", "type" => "fill"} = record, {order, groups, fills}),
    do: {order, groups, [record | fills]}

  defp collect(%{"kind" => "broker", "group_id" => id} = record, {order, groups, fills})
       when is_binary(id) do
    case Map.fetch(groups, id) do
      {:ok, group} -> {order, Map.put(groups, id, add(group, record)), fills}
      :error -> {[id | order], Map.put(groups, id, add(%__MODULE__{id: id}, record)), fills}
    end
  end

  defp collect(_record, acc), do: acc

  # Records and verdicts accumulate newest-first; `finish/1` restores order.
  defp add(group, record) do
    group = %{group | records: [record | group.records]}

    case record["type"] do
      "intent" -> %{group | intent: record["intent"], opened_at: record["at"]}
      "context" -> %{group | context: record["context"]}
      "verdict" -> %{group | verdicts: [record | group.verdicts]}
      "order" -> %{group | order: record}
      "close" -> %{group | close: record}
      _review_or_unknown -> group
    end
  end

  defp finish(group),
    do: %{group | records: Enum.reverse(group.records), verdicts: Enum.reverse(group.verdicts)}

  @doc "The group's outcome (see the moduledoc)."
  @spec outcome(t()) :: outcome()
  def outcome(%__MODULE__{order: %{"status" => "placed"}}), do: :placed
  def outcome(%__MODULE__{order: %{}}), do: :failed
  def outcome(%__MODULE__{close: %{"outcome" => "unknown"}}), do: :unknown
  def outcome(%__MODULE__{close: %{}}), do: :denied

  def outcome(%__MODULE__{} = group) do
    case last_verdict(group) do
      %{"result" => %{"action" => "deny"}} -> :denied
      _other -> :open
    end
  end

  @doc "The latest verdict record, or nil."
  @spec last_verdict(t()) :: map() | nil
  def last_verdict(%__MODULE__{verdicts: verdicts}), do: List.last(verdicts)

  @doc """
  How a group left open by a crash is closed: `{reason, outcome}`. After a
  post-review ALLOW the order call may have gone out, so the outcome is
  `"unknown"`; anything earlier never reached a final verdict and is a DENY.
  """
  @spec crash_close(t()) :: {String.t(), String.t()}
  def crash_close(%__MODULE__{} = group) do
    case last_verdict(group) do
      %{"phase" => "post_review", "result" => %{"action" => "allow"}} ->
        {"crash_outcome_unknown", "unknown"}

      _other ->
        {"crash_before_verdict", "deny"}
    end
  end

  @doc "Does the group count toward notional and order rate?"
  @spec counts?(t()) :: boolean()
  def counts?(%__MODULE__{intent: intent} = group),
    do:
      outcome(group) in [:placed, :unknown] and
        match?(%{"kind" => kind} when kind != "cancel", intent)

  @doc """
  When a counted group's order happened: the order record's time, or for an
  unknown outcome the time of the last record before the crash close.
  """
  @spec counted_at(t()) :: String.t() | nil
  def counted_at(%__MODULE__{order: %{"at" => at}}), do: at

  def counted_at(%__MODULE__{records: records}) do
    records
    |> Enum.reject(&(&1["type"] == "close"))
    |> List.last()
    |> case do
      %{"at" => at} -> at
      nil -> nil
    end
  end
end
