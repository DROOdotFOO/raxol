defmodule Raxol.Agent.Journal.Tip do
  @moduledoc """
  The FROZEN conversational-tip predicate — the single contract implementation
  of `conversational?/1` and `tip/2`.

  Frozen by `docs/proposals/in-flight/harness-freeze-contracts.md` §1.1 "The
  conversational tip" (JS-FREEZE). U4 (reattach, AD-15/FI-12) locates the resume
  point by a backward scan under this predicate; U9 (checkpoint, AD-10) validates
  its stamped `tip_offset` against it. Both units consume THIS module — neither
  re-invents tip semantics (that shared re-invention was the U4∥U9 false parallel
  the freeze dissolves at the contract layer).

  ## The predicate (verbatim from §1.1)

      conversational?(record) :=
        record.kind == "event"
        ∧ record.family == "loop"
        ∧ record.type ∈ CONVERSATIONAL

      tip(journal, branch := "main") :=
        the record with the HIGHEST offset satisfying
        (record.branch_id == branch ∧ conversational?(record))
        (undefined on an empty/no-conversational branch → :no_tip)

  ## Frozen decisions this module encodes

    * **The grandfather clause.** A record with no `"kind"` reads as `"event"`; a
      record with no `"branch_id"` reads as `"main"`. Every pre-freeze journal
      (which stamps neither) therefore keeps its historical tip byte-for-byte.
    * **The closure rule.** `CONVERSATIONAL` is a whitelist and the ONLY door:
      every future record kind and every future `family: "loop"` type is
      tip-excluded unless explicitly added here. Nothing becomes a tip by default.
    * **The Dormammu exclusion (FI-12).** `state_change`, `idle`, every
      `family: "meta"` event, every non-`"event"` kind, and — deliberately, though
      it is `family: "loop"` — `woken` are excluded. A trailing checkpoint / meta
      event / idle marker / `woken` must never be selected as the tip.
    * **`approval_requested` IS included** — a pending approval is exactly where a
      resumed conversation must land (emitted `family: "loop"`, not `:meta`).

  This module is pure and reader-side only: it never touches the journal, the
  bus, or a writer. It reads decoded journal records (string-keyed maps) as
  produced by the tolerant Reader or by an independent raw decoder — that dual
  sourcing is what the U4-R dual-oracle tip-determinism property (P-JS2) checks.
  """

  # CONVERSATIONAL — the frozen, grow-only whitelist (§1.1). `item_started` and
  # `approval_requested` are members from day one (OQ-JS3 RULED: INCLUDE). Adding
  # a member is a `schema_version` minor bump; removing one is forbidden (it would
  # silently move historical tips).
  @conversational ~w(
    turn_started
    item_started
    item_completed
    turn_completed
    turn_canceled
    error
    approval_requested
  )

  @doc "The frozen CONVERSATIONAL whitelist (§1.1), as a list of type strings."
  @spec conversational_types() :: [String.t()]
  def conversational_types, do: @conversational

  @doc """
  Is `record` a conversational loop event — a legal tip candidate?

  `true` iff `kind == "event"` (grandfathered from absent), `family == "loop"`,
  and `type ∈ CONVERSATIONAL`. Everything else — checkpoints, `family: "meta"`
  events, `idle`/`woken`/`state_change` loop events, unknown future kinds — is
  `false`, by the closure rule.
  """
  @spec conversational?(map()) :: boolean()
  def conversational?(record) when is_map(record) do
    kind(record) == "event" and
      family(record) == "loop" and
      type(record) in @conversational
  end

  @doc """
  The conversational tip of `records` on `branch` (default `"main"`).

  Returns `{:tip, offset}` for the highest-offset record satisfying
  `branch_id == branch ∧ conversational?`, or `:no_tip` when the branch has no
  conversational record. `records` may arrive in any order — the tip is defined
  by highest offset, not list position (a backward scan and a `max_by` agree).

  `tip(records)` is shorthand for `tip(records, "main")`; every pre-`branch_id`
  record reads as branch `"main"`, so the default is grandfather-safe.
  """
  @spec tip([map()], String.t()) :: {:tip, non_neg_integer()} | :no_tip
  def tip(records, branch \\ "main") when is_list(records) do
    records
    |> Enum.filter(fn record ->
      branch_id(record) == branch and conversational?(record)
    end)
    |> case do
      [] -> :no_tip
      matches -> {:tip, matches |> Enum.max_by(&offset/1) |> offset()}
    end
  end

  # --- field access with the frozen grandfather defaults ----------------------

  # §1.1 grandfather clause: absent "kind" ⇒ "event".
  defp kind(record), do: to_string(Map.get(record, "kind", "event"))

  # §1.1 grandfather clause: absent "branch_id" ⇒ "main".
  defp branch_id(record), do: to_string(Map.get(record, "branch_id", "main"))

  # family/type have no default — a real event record always stamps them, and a
  # record missing family can never satisfy `family == "loop"`.
  defp family(record), do: as_string(Map.get(record, "family"))
  defp type(record), do: as_string(Map.get(record, "type"))

  defp offset(record), do: Map.fetch!(record, "id")

  defp as_string(nil), do: nil
  defp as_string(value), do: to_string(value)
end
