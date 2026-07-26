defmodule Raxol.Symphony.Worker.HostPool do
  @moduledoc """
  A pure host-slot allocator enforcing **one-worker-lifetime-per-host**
  (issue #742).

  Each configured `Raxol.Symphony.Worker.HostSpec` is a slot that holds at
  most one worker at a time. The orchestrator `claim/1`s a free slot before
  spawning a worker and `release/2`s it when the worker exits. With no hosts
  configured, `new/1` returns `nil` and the orchestrator skips gating
  entirely (local dispatch, unchanged).

  Pure and immutable: `claim/1` returns the updated pool. Slot order is
  preserved so allocation is deterministic (first free slot wins).
  """

  alias Raxol.Symphony.Worker.HostSpec

  @enforce_keys [:slots]
  defstruct [:slots]

  @type slot :: %{spec: HostSpec.t(), busy?: boolean()}
  @type t :: %__MODULE__{slots: [slot()]}

  @doc """
  Build a pool from normalized specs. Returns `nil` for an empty list — the
  orchestrator reads `nil` as "no host gating".
  """
  @spec new([HostSpec.t()]) :: t() | nil
  def new([]), do: nil

  def new(specs) when is_list(specs) do
    %__MODULE__{slots: Enum.map(specs, &%{spec: &1, busy?: false})}
  end

  @doc """
  Claim the first free slot. Returns `{:ok, spec, pool}` with that slot
  marked busy, or `:none_free` when every host is occupied.

  Exactly ONE slot flips per claim, addressed by position — two entries
  that share a `HostSpec.id/1` (duplicate targets) stay independent slots,
  so N identical hosts still provide N concurrent workers.
  """
  @spec claim(t()) :: {:ok, HostSpec.t(), t()} | :none_free
  def claim(%__MODULE__{slots: slots} = pool) do
    case Enum.find_index(slots, &(not &1.busy?)) do
      nil -> :none_free
      idx -> {:ok, Enum.at(slots, idx).spec, mark_at(pool, idx, true)}
    end
  end

  @doc """
  Release the slot for `spec`, marking one busy match free. A no-op if the
  host is not in the pool or is already free (idempotent). Frees exactly one
  slot, so duplicate-id hosts release independently rather than collapsing.
  """
  @spec release(t(), HostSpec.t()) :: t()
  def release(%__MODULE__{slots: slots} = pool, %HostSpec{} = spec) do
    id = HostSpec.id(spec)

    case Enum.find_index(slots, &(&1.busy? and HostSpec.id(&1.spec) == id)) do
      nil -> pool
      idx -> mark_at(pool, idx, false)
    end
  end

  @doc "Count of free slots."
  @spec free_count(t()) :: non_neg_integer()
  def free_count(%__MODULE__{slots: slots}),
    do: Enum.count(slots, &(not &1.busy?))

  @doc "Count of busy slots."
  @spec busy_count(t()) :: non_neg_integer()
  def busy_count(%__MODULE__{slots: slots}), do: Enum.count(slots, & &1.busy?)

  @doc "Total slot count."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{slots: slots}), do: length(slots)

  defp mark_at(%__MODULE__{slots: slots} = pool, idx, busy?) do
    %{pool | slots: List.update_at(slots, idx, &%{&1 | busy?: busy?})}
  end
end
