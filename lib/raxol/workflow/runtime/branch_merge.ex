defmodule Raxol.Workflow.Runtime.BranchMerge do
  @moduledoc """
  Merges the terminal states of fan-out branches at a join.

  A join carrying an explicit `:reduce` reducer delegates the whole
  list of branch states to that function. Otherwise the branch states
  fold left-to-right in branch-index order: a key declared on a
  `Raxol.Workflow.Channel` is combined via the channel's `:with`
  reducer, and any other key is last-write-wins by branch order.

  Pure: given the same branch states, join, and channels it always
  returns the same merged state and touches nothing outside its
  arguments.
  """

  alias Raxol.Workflow.Channel
  alias Raxol.Workflow.Edge.JoinEdge

  @doc """
  Merge `branch_states` (in branch-index order) into a single state
  according to the join's reducer or the graph's declared channels.
  """
  @spec merge([map()], JoinEdge.t(), %{optional(term()) => Channel.t()}) ::
          map()
  def merge(branch_states, %JoinEdge{reducer: reducer}, _channels)
      when is_function(reducer, 1) do
    reducer.(branch_states)
  end

  def merge([first | rest], %JoinEdge{reducer: nil}, channels) do
    channel_index = channel_index_by_key(channels)

    Enum.reduce(rest, first, fn next_state, acc ->
      reduce_branch_into(acc, next_state, channel_index)
    end)
  end

  defp channel_index_by_key(channels) do
    channels
    |> Map.values()
    |> Map.new(fn %Channel{into: key} = c -> {key, c} end)
  end

  defp reduce_branch_into(left, right, channel_index) do
    Enum.reduce(Map.keys(right), left, fn key, acc ->
      case Map.fetch(right, key) do
        :error ->
          acc

        {:ok, right_val} ->
          case Map.get(channel_index, key) do
            %Channel{with: reducer} ->
              Map.update(acc, key, right_val, fn left_val ->
                reducer.(left_val, right_val)
              end)

            nil ->
              Map.put(acc, key, right_val)
          end
      end
    end)
  end
end
