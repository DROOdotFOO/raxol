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

  @type slot :: %{spec: HostSpec.t(), busy?: boolean(), draining?: boolean()}
  @type t :: %__MODULE__{slots: [slot()]}

  @doc """
  Build a pool from normalized specs. Returns `nil` for an empty list — the
  orchestrator reads `nil` as "no host gating".
  """
  @spec new([HostSpec.t()]) :: t() | nil
  def new([]), do: nil

  def new(specs) when is_list(specs) do
    %__MODULE__{slots: Enum.map(specs, &free_slot/1)}
  end

  @doc """
  Reconcile a pool against a freshly-adopted `desired` spec list (config
  hot-reload). Preserves every busy slot; a busy slot whose host is no longer
  desired is marked **draining** (kept out of allocation, dropped when its
  worker releases it). Free slots are rebuilt from the desired list so added
  hosts gain capacity and removed free hosts disappear. Returns `nil` when the
  result is empty (no gating), mirroring `new/1`.
  """
  @spec reconcile(t() | nil, [HostSpec.t()]) :: t() | nil
  def reconcile(pool, desired) when is_list(desired) do
    wanted = id_counts(desired)

    # Keep busy slots; satisfy a wanted occurrence if the host survives,
    # otherwise flag the slot for drain. Re-adding a still-draining host
    # un-drains it (a wanted occurrence is available again).
    {kept, wanted} =
      pool
      |> slots()
      |> Enum.filter(& &1.busy?)
      |> Enum.map_reduce(wanted, fn slot, wanted ->
        id = HostSpec.id(slot.spec)

        case Map.get(wanted, id, 0) do
          n when n > 0 -> {%{slot | draining?: false}, Map.put(wanted, id, n - 1)}
          _none -> {%{slot | draining?: true}, wanted}
        end
      end)

    # A fresh free slot for each desired occurrence not already covered by a
    # kept busy slot, in declared order so allocation stays deterministic.
    {fresh, _wanted} =
      Enum.flat_map_reduce(desired, wanted, fn spec, wanted ->
        id = HostSpec.id(spec)

        case Map.get(wanted, id, 0) do
          n when n > 0 -> {[free_slot(spec)], Map.put(wanted, id, n - 1)}
          _covered -> {[], wanted}
        end
      end)

    case kept ++ fresh do
      [] -> nil
      slots -> %__MODULE__{slots: slots}
    end
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
      nil ->
        pool

      idx ->
        # A draining slot (host removed by a reconcile while busy) is dropped
        # on release rather than freed, so a gone host never gets re-claimed.
        if Enum.at(slots, idx).draining? do
          %{pool | slots: List.delete_at(slots, idx)}
        else
          mark_at(pool, idx, false)
        end
    end
  end

  @doc """
  Re-hold a slot for `spec`, marking one matching free slot busy. Used to keep
  a paused worker's host reserved across a resume and to re-hold slots after a
  restart rebuilt the pool. Idempotent: if a matching slot is already busy the
  pool is returned unchanged (no second slot is taken); a no-op when the host
  is absent.
  """
  @spec hold(t() | nil, HostSpec.t()) :: t() | nil
  def hold(nil, %HostSpec{}), do: nil

  def hold(%__MODULE__{slots: slots} = pool, %HostSpec{} = spec) do
    id = HostSpec.id(spec)

    cond do
      Enum.any?(slots, &(&1.busy? and HostSpec.id(&1.spec) == id)) ->
        pool

      true ->
        case Enum.find_index(slots, &(not &1.busy? and HostSpec.id(&1.spec) == id)) do
          nil -> pool
          idx -> mark_at(pool, idx, true)
        end
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

  @doc "Count of slots marked draining (removed host still holding a worker)."
  @spec draining_count(t() | nil) :: non_neg_integer()
  def draining_count(nil), do: 0
  def draining_count(%__MODULE__{slots: slots}), do: Enum.count(slots, & &1.draining?)

  @doc "Every slot's `HostSpec.id/1`, in slot order (for change detection)."
  @spec host_ids(t() | nil) :: [binary()]
  def host_ids(nil), do: []
  def host_ids(%__MODULE__{slots: slots}), do: Enum.map(slots, &HostSpec.id(&1.spec))

  defp mark_at(%__MODULE__{slots: slots} = pool, idx, busy?) do
    %{pool | slots: List.update_at(slots, idx, &%{&1 | busy?: busy?})}
  end

  defp free_slot(%HostSpec{} = spec), do: %{spec: spec, busy?: false, draining?: false}

  defp slots(nil), do: []
  defp slots(%__MODULE__{slots: slots}), do: slots

  defp id_counts(specs) do
    Enum.reduce(specs, %{}, fn spec, acc ->
      Map.update(acc, HostSpec.id(spec), 1, &(&1 + 1))
    end)
  end
end
