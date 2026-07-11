defmodule Raxol.UI.Layout.Flexbox.Solver do
  @moduledoc """
  Resolve flexible lengths per CSS Flexbox spec section 9.7, on resolved
  `Raxol.UI.Layout.FlexItem`s. Called from
  `Flexbox.calculate_single_line_layout/5` for every flex line.

    * free space computed from OUTER sizes (margins included; `:auto`
      margins count as 0 during sizing — positioning distributes into them)
    * inflexible items and items whose clamped hypothetical size differs
      from their base size freeze BEFORE the loop
    * iterative clamp-freeze-redistribute until no min/max violations
      (bounded by the item count)
    * exact integer accounting: each round distributes whole cells via
      largest-remainder, so no free space is silently lost to `div`
      truncation

  Not implemented (documented divergence): the fractional-flex-factor rule
  (sum of factors < 1 leaves proportional free space undistributed) —
  factors here are non-negative integers, so a fractional sum cannot occur.
  """

  alias Raxol.UI.Layout.FlexItem

  @doc """
  Solves main sizes for `items` inside `container_main` cells (the
  container's content-box main size, gaps already subtracted by the caller).

  Returns items in original order, each with `main_size` set and frozen.
  """
  def resolve_flexible_lengths(items, container_main, main_axis)
      when is_list(items) and is_integer(container_main) do
    indexed = Enum.with_index(items)

    outer_hypo_sum =
      Enum.reduce(items, 0, fn item, acc ->
        acc + FlexItem.outer_main(item, FlexItem.hypothetical_main(item), main_axis)
      end)

    mode = if outer_hypo_sum < container_main, do: :grow, else: :shrink

    {frozen, unfrozen} =
      Enum.split_with(indexed, fn {item, _i} -> initially_frozen?(item, mode) end)

    frozen =
      Enum.map(frozen, fn {item, i} ->
        {freeze(item, FlexItem.hypothetical_main(item), :inflexible), i}
      end)

    (frozen ++ iterate(unfrozen, frozen, container_main, main_axis, mode, length(items) + 1))
    |> Enum.sort_by(fn {_item, i} -> i end)
    |> Enum.map(fn {item, _i} -> item end)
  end

  # -- loop ---------------------------------------------------------------

  defp iterate([], _frozen, _container, _axis, _mode, _fuel), do: []

  defp iterate(unfrozen, frozen, container, axis, mode, fuel) when fuel > 0 do
    free = free_space(unfrozen, frozen, container, axis)

    candidates = distribute(unfrozen, free, mode)

    {violators, satisfied} =
      Enum.split_with(candidates, fn {item, _i, candidate} ->
        FlexItem.clamp_main(item, candidate) != candidate
      end)

    total_violation =
      Enum.reduce(violators, 0, fn {item, _i, candidate}, acc ->
        acc + (FlexItem.clamp_main(item, candidate) - candidate)
      end)

    cond do
      violators == [] ->
        Enum.map(candidates, fn {item, i, candidate} ->
          {freeze(item, candidate, nil), i}
        end)

      total_violation > 0 ->
        # min violations dominate: freeze items clamped UP at their min
        freeze_and_continue(violators, satisfied, frozen, container, axis, mode, fuel, :min_violation)

      true ->
        freeze_and_continue(violators, satisfied, frozen, container, axis, mode, fuel, :max_violation)
    end
  end

  # Fuel exhausted (cannot happen: every round freezes >= 1 item) — freeze
  # everything at clamped candidates rather than looping forever.
  defp iterate(unfrozen, _frozen, _container, _axis, _mode, _fuel) do
    Enum.map(unfrozen, fn {item, i} ->
      {freeze(item, FlexItem.hypothetical_main(item), :fuel_exhausted), i}
    end)
  end

  defp freeze_and_continue(violators, satisfied, frozen, container, axis, mode, fuel, reason) do
    reason_matches = fn {item, _i, candidate} ->
      case reason do
        :min_violation -> FlexItem.clamp_main(item, candidate) > candidate
        :max_violation -> FlexItem.clamp_main(item, candidate) < candidate
      end
    end

    {to_freeze, back} = Enum.split_with(violators, reason_matches)

    newly_frozen =
      Enum.map(to_freeze, fn {item, i, candidate} ->
        {freeze(item, FlexItem.clamp_main(item, candidate), reason), i}
      end)

    still_unfrozen =
      Enum.map(back ++ satisfied, fn {item, i, _candidate} -> {item, i} end)

    newly_frozen ++
      iterate(still_unfrozen, newly_frozen ++ frozen, container, axis, mode, fuel - 1)
  end

  # -- distribution ---------------------------------------------------------

  # Distributes `free` (may be negative in shrink mode) across unfrozen
  # items proportionally, returning {item, index, candidate_size}. Whole
  # cells only; the fractional residue is assigned by largest remainder so
  # the distributed total is exact.
  defp distribute(unfrozen, free, mode) do
    weights =
      Enum.map(unfrozen, fn {item, _i} -> weight(item, mode) end)

    total_weight = Enum.sum(weights)

    if total_weight == 0 do
      Enum.map(unfrozen, fn {item, i} -> {item, i, item.base_size} end)
    else
      exact =
        Enum.zip(unfrozen, weights)
        |> Enum.map(fn {{item, i}, w} ->
          {item, i, item.base_size + free * w / total_weight}
        end)

      apportion(exact, free)
    end
  end

  defp weight(item, :grow), do: item.grow
  defp weight(item, :shrink), do: item.shrink * item.base_size

  # Largest-remainder rounding: floor everything, hand out the remaining
  # cells (sign-aware) to the largest fractional parts.
  defp apportion(exact, free) do
    floored =
      Enum.map(exact, fn {item, i, x} ->
        base = snap_candidate(x, free)
        {item, i, base, abs(x - base)}
      end)

    assigned = Enum.reduce(floored, 0, fn {item, _i, s, _r}, acc -> acc + (s - item.base_size) end)
    residue = free - assigned
    step = if residue >= 0, do: 1, else: -1

    floored
    |> Enum.sort_by(fn {_item, _i, _s, r} -> -r end)
    |> assign_residue(abs(residue), step)
    |> Enum.sort_by(fn {_item, i, _s} -> i end)
  end

  # Floor in grow mode, ceil in shrink mode; apportion/2 then assigns the
  # signed residue by largest remainder. The floor/ceil split is what keeps
  # the integer accounting exact — replacing it with a plain truncation
  # breaks the exact-sum invariant.
  defp snap_candidate(x, free) when free >= 0, do: trunc(:math.floor(x))
  defp snap_candidate(x, _free), do: trunc(:math.ceil(x))

  defp assign_residue(entries, 0, _step),
    do: Enum.map(entries, fn {item, i, s, _r} -> {item, i, s} end)

  defp assign_residue([{item, i, s, _r} | rest], n, step),
    do: [{item, i, s + step} | assign_residue(rest, n - 1, step)]

  defp assign_residue([], _n, _step), do: []

  # -- helpers ----------------------------------------------------------------

  defp initially_frozen?(item, mode) do
    hypo = FlexItem.hypothetical_main(item)

    case mode do
      :grow -> item.grow == 0 or hypo < item.base_size
      :shrink -> item.shrink == 0 or hypo > item.base_size
    end
  end

  defp free_space(unfrozen, frozen, container, axis) do
    used_frozen =
      Enum.reduce(frozen, 0, fn {item, _i}, acc ->
        acc + FlexItem.outer_main(item, item.main_size, axis)
      end)

    used_unfrozen =
      Enum.reduce(unfrozen, 0, fn {item, _i}, acc ->
        acc + FlexItem.outer_main(item, item.base_size, axis)
      end)

    container - used_frozen - used_unfrozen
  end

  defp freeze(item, size, reason) do
    %{item | frozen: true, frozen_reason: reason, main_size: max(0, size)}
  end
end
