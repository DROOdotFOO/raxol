defmodule Raxol.Harness.Fixture.Projectors.Identity do
  @moduledoc """
  Trivial identity-shaped projector: one summary row per envelope, in
  offset (line-number) order. Stand-in for the real journal-fold
  projection (roadmap T7) so `mix raxol.harness.fixtures.bless` is
  testable before that projection lands. Deterministic and pure — no
  fold/tier routing, no block model, just enough shape to exercise the
  bless task's round trip.

  NOT T7's identity. This projector dumps the full envelope stream —
  ephemeral `item_delta` rows included — which is bless-task plumbing,
  nothing more. The projection identity defined in 06-projection §2
  (`identity(fixture) = {durable_block_list, fold_defaults}`) excludes
  ephemeral events entirely; when T7's real projector lands it replaces
  this module for semantic snapshots, and the `.blocks.json` files are
  re-blessed against it (an intentional, reviewed churn).
  """

  @behaviour Raxol.Harness.Fixture.Projector

  alias Raxol.Harness.Fixture.Session

  @impl true
  def project(%Session{envelopes: envelopes}) do
    Enum.map(envelopes, fn envelope ->
      %{
        offset: envelope.offset,
        id: envelope.body.id,
        turn_id: envelope.body.turn_id,
        family: envelope.body.family,
        type: envelope.body.type,
        tier: envelope.body.tier
      }
    end)
  end
end
