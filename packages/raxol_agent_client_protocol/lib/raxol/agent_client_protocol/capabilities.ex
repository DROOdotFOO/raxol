defmodule Raxol.AgentClientProtocol.Capabilities do
  @moduledoc """
  The negotiated-capability PREDICATE (design doc §6, artifact #3 / connection
  design deviation #3): given a `Connection`'s snapshotted capability tree,
  decide whether a wire method is negotiated and therefore permitted.

  This is the security-relevant half of the capability gate. `MethodTable`
  owns the `:capability` column (which method is gated, by which struct-field
  path — see its `capability` typedoc and the ORACLE-DIVERGENCE note); this
  module resolves a path against a live snapshot.

  ## Which snapshot

  The gate lives on the **receiver** and checks the receiver's OWN advertised
  capabilities (`Connection.capability_denied?/2`, before `Router.decode/4`):

    * an **agent** rejects an inbound client→agent method it never advertised
      (`session/load` unless it advertised `loadSession`, …) — the snapshot is
      the agent's own `AgentCapabilities` (from the `initialize` RESPONSE it
      sent);
    * a **client** rejects an inbound agent→client callback it never advertised
      (`terminal/*` unless it advertised `terminal`, `fs/write_text_file`
      unless it advertised `fileSystem.writeTextFile`, …) — the snapshot is the
      client's own `ClientCapabilities` (from the `initialize` REQUEST it sent).

  Because every gated wire method is single-direction and its `MethodTable`
  capability tag (`:agent` / `:client`) matches the side that HANDLES it,
  `negotiated?/2` needs only the receiver's snapshot and the method string —
  the tag is not consulted for resolution (it is a compile-time assertion,
  invariant 7).

  ## Fail closed

  Resolution walks the field path from the snapshot struct. A truthy leaf
  (`true`, or a present nested capability struct/map) ⇒ negotiated. **Anything
  else — a missing field, a `nil`/`false` leaf, a `nil` snapshot, or an
  `:never`-gated method — is NOT negotiated.** Absent capability is denial, by
  design: the `Connection` maps a non-negotiated gated method to `-32601`
  BEFORE decode (so `-32601` beats `-32602`). Baseline methods (`capability:
  nil` in the table — `initialize`, `session/new`, `session/prompt`,
  `session/cancel`, …) are always available. An unknown method is NOT a
  capability denial (`decode/4` answers it with `-32601` on its own).
  """

  alias Raxol.AgentClientProtocol.MethodTable

  @doc """
  Is `method` negotiated given the receiver's own capability snapshot `caps`?

  `caps` is the snapshotted `AgentCapabilities` / `ClientCapabilities` struct
  (or `nil` pre-handshake). Pure and total — never raises, even for a `nil` or
  malformed snapshot (both resolve to "not negotiated" for a gated method).
  """
  @spec negotiated?(term(), String.t()) :: boolean()
  def negotiated?(caps, method) when is_binary(method) do
    case MethodTable.capability_for(method) do
      # Baseline method, or a method not in the table (decode -32601s it): a
      # capability gate must not deny it — only the caps-gated rows can deny.
      :none -> true
      :unknown_method -> true
      # Oracle-gated by a capability the ported struct cannot express.
      :never -> false
      {_side, path} -> resolve(caps, path)
    end
  end

  # Walk the field path. Each step must land on a map/struct to descend; the
  # first non-map (a missing/`nil` intermediate) halts to `nil`. Only the FINAL
  # leaf's truthiness decides — a present intermediate struct is truthy but we
  # keep walking. `Map.get/2` reads struct fields by atom key without creating
  # atoms (the path atoms are compile-time literals from `MethodTable`).
  defp resolve(caps, path) do
    path
    |> Enum.reduce_while(caps, fn segment, acc ->
      case acc do
        %{} = map -> {:cont, Map.get(map, segment)}
        _ -> {:halt, nil}
      end
    end)
    |> truthy?()
  end

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_present), do: true
end
