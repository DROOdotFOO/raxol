defmodule Raxol.Broker.Journal.Groups do
  @moduledoc """
  Folds broker journal records into decision groups. Pure: shared by
  `Raxol.Broker.Journal` (crash recovery and the ETS index) and the replay
  renderer, so both read a journal the same way.

  A group is the records sharing one `group_id`: intent, context snapshot,
  verdicts (`pre_review`, then `post_review`), review responses, approvals of
  an ASK, a `placing` record written just before the order call, and one
  terminal record. Its outcome:

  | Outcome | When |
  | --- | --- |
  | `:placed` | an `order` record with status `placed` |
  | `:failed` | an `order` record with status `failed` |
  | `:unknown` | an `order` record with status `unknown`, or a `close` record with outcome `unknown`: the order call may have gone out and its result is not known |
  | `:denied` | a DENY verdict, a declined approval, or a `close` record with outcome `deny` |
  | `:in_flight` | a `placing` record and no terminal record yet |
  | `:open` | none of the above yet |

  An order counts toward notional and order rate from its `placing` record,
  at the notional recorded there, until an order response says it failed:
  `:placed`, `:unknown` and `:in_flight` groups count unless their recorded
  notional is `nil` (cancels).
  """

  defstruct [
    :id,
    :opened_at,
    :intent,
    :context,
    :placing,
    :order,
    :close,
    records: [],
    verdicts: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          opened_at: String.t() | nil,
          intent: map() | nil,
          context: map() | nil,
          placing: map() | nil,
          order: map() | nil,
          close: map() | nil,
          records: [map()],
          verdicts: [map()]
        }

  @type outcome :: :open | :in_flight | :denied | :placed | :failed | :unknown

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
      "placing" -> %{group | placing: record}
      "order" -> %{group | order: record}
      "close" -> %{group | close: record}
      _review_approval_or_unknown -> group
    end
  end

  defp finish(group),
    do: %{group | records: Enum.reverse(group.records), verdicts: Enum.reverse(group.verdicts)}

  @doc "The group's outcome (see the moduledoc)."
  @spec outcome(t()) :: outcome()
  def outcome(%__MODULE__{order: %{"status" => "placed"}}), do: :placed
  def outcome(%__MODULE__{order: %{"status" => "unknown"}}), do: :unknown
  def outcome(%__MODULE__{order: %{}}), do: :failed
  def outcome(%__MODULE__{close: %{"outcome" => "unknown"}}), do: :unknown
  def outcome(%__MODULE__{close: %{}}), do: :denied

  def outcome(%__MODULE__{} = group) do
    cond do
      declined?(group) -> :denied
      match?(%{"result" => %{"action" => "deny"}}, last_verdict(group)) -> :denied
      group.placing != nil -> :in_flight
      true -> :open
    end
  end

  defp declined?(%__MODULE__{records: records}),
    do: Enum.any?(records, &match?(%{"type" => "approval", "decision" => "declined"}, &1))

  @doc "The latest verdict record, or nil."
  @spec last_verdict(t()) :: map() | nil
  def last_verdict(%__MODULE__{verdicts: verdicts}), do: List.last(verdicts)

  @doc """
  How a group left open by a crash is closed: `{reason, outcome}`. With a
  `placing` record the order call may have gone out, so the outcome is
  `"unknown"` and the group keeps counting; without one no order was sent and
  the group is a DENY.
  """
  @spec crash_close(t()) :: {String.t(), String.t()}
  def crash_close(%__MODULE__{placing: %{}}), do: {"crash_outcome_unknown", "unknown"}
  def crash_close(%__MODULE__{}), do: {"crash_before_verdict", "deny"}

  @doc """
  Does the group count toward notional and order rate? From its `placing`
  record until an order response says it failed, and only with a recorded
  notional (cancels record none).
  """
  @spec counts?(t()) :: boolean()
  def counts?(%__MODULE__{placing: %{"notional" => notional}} = group) when notional != nil,
    do: outcome(group) in [:placed, :unknown, :in_flight]

  def counts?(%__MODULE__{}), do: false

  @doc "When a counted group's order is counted: the time of its `placing` record."
  @spec counted_at(t()) :: String.t() | nil
  def counted_at(%__MODULE__{placing: %{"at" => at}}), do: at
  def counted_at(%__MODULE__{}), do: nil
end
