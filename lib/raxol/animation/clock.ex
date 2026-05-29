defmodule Raxol.Animation.Clock do
  @moduledoc """
  Time source for the animation system.

  By default this is the wall clock (`System.system_time(:millisecond)`), so
  live rendering is unaffected. Offline renderers (the video render target) can
  `freeze/1` it to a fixed virtual time, making every captured frame
  deterministic regardless of how long rasterization actually takes.

  Both the per-frame "now" (`Raxol.Animation.AnimationProcessor`) and an
  animation's `start_time` (`Raxol.Animation.Lifecycle`) read through here, so a
  frozen clock keeps interpolation coherent across the two.

  The freeze is global to the BEAM node. Freeze only while driving a dedicated,
  offline render; do not freeze while serving live animated UIs on the same node.
  """

  @table __MODULE__

  @doc "Current animation time in milliseconds (frozen value if set, else wall clock)."
  @spec now() :: integer()
  def now do
    case lookup() do
      nil -> System.system_time(:millisecond)
      frozen -> frozen
    end
  end

  @doc "Pin animation time to `ms` until `unfreeze/0`."
  @spec freeze(integer()) :: :ok
  def freeze(ms) when is_integer(ms) do
    ensure_table()
    :ets.insert(@table, {:frozen, ms})
    :ok
  end

  @doc "Resume wall-clock time."
  @spec unfreeze() :: :ok
  def unfreeze do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, :frozen)
    :ok
  end

  @doc "Whether the clock is currently frozen."
  @spec frozen?() :: boolean()
  def frozen?, do: not is_nil(lookup())

  defp lookup do
    with tid when tid != :undefined <- :ets.whereis(@table),
         [{:frozen, ms}] <- :ets.lookup(@table, :frozen) do
      ms
    else
      _ -> nil
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set])
        rescue
          ArgumentError -> :ok
        end

      _tid ->
        :ok
    end
  end
end
