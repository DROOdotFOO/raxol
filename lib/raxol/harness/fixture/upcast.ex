defmodule Raxol.Harness.Fixture.Upcast do
  @moduledoc """
  Upcast-on-read: fills absent newer fields with declared defaults, never
  mutates the bytes on disk (06-projection §1.2, methodology R6
  "contract-only-grows"). Operates purely on the already-decoded struct.

  One clause per version bump is the intended shape as the contract grows;
  today only `envelope_v = 1` exists, so `to_current/2` is the identity
  pass on the version dimension plus the (version-independent)
  default-fill pass for fields that are optional-but-absent on any
  fixture recorded before they existed (`scope`, `provenance` — not yet
  emitted by `Raxol.Agent.Contract` v0).

  ## Trust default is fail-safe, not fail-open (FI-5)

  When `provenance` is absent, the filled `trust` value depends on what
  the payload derives from: an `item_type: "tool_result"` payload is tool
  output of unknown origin and defaults to `:tainted` — unknown-origin
  tool data must never launder to trusted through a missing field.
  Everything else defaults to `:trusted` with `source: "primary"`.
  (Tainting `item_delta` chunks that belong to a tool_result item would
  require cross-envelope item correlation; upcast is a pure per-envelope
  function, so that tracking belongs to the projection layer, not here.)

  Documented deviation from `harness-spec-protocol.md` §3: `source` is a
  `String.t()` on the wire and in the decoded struct (the spec sketches
  `source: atom()`) — deliberate, so fixture decode never mints atoms
  from disk bytes.

  ## Evolution promise (what upcast does and does not cover)

  Upcast-forever applies to **defaultable** fields: a new field whose
  absence has a sensible default gets a fill clause here and every
  frozen fixture keeps loading. A **content-bearing** new field (one
  whose value carries information no default can invent — a new payload
  member the projection renders, say) means the golden sessions are
  re-recorded at the new version; upcast must not fabricate content.
  Byte-exactness is a `<name>.blocks.json` claim (projection
  determinism over a loaded session), NOT a promise that `.jsonl`
  fixtures never change — they are frozen per version, re-recorded on
  content-bearing growth.
  """

  alias Raxol.Harness.Fixture.Envelope

  @current_version 1

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc """
  Upcast a decoded envelope recorded at `recorded_version` to the current
  schema shape.
  """
  @spec to_current(pos_integer(), Envelope.t()) :: Envelope.t()
  def to_current(_recorded_version, %Envelope{body: body} = envelope) do
    %{envelope | body: fill_event_defaults(body)}
  end

  defp fill_event_defaults(event) do
    event
    |> Map.update!(:scope, &(&1 || :session))
    |> fill_provenance()
  end

  defp fill_provenance(%{provenance: nil} = event) do
    %{event | provenance: %{source: "primary", trust: default_trust(event)}}
  end

  defp fill_provenance(event), do: event

  defp default_trust(%{payload: %{"item_type" => "tool_result"}}), do: :tainted
  defp default_trust(_event), do: :trusted
end
