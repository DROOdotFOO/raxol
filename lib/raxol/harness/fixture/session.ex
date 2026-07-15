defmodule Raxol.Harness.Fixture.Session do
  @moduledoc """
  A fully-loaded fixture: header + the ordered, upcasted envelope list.
  Helpers here are read-only projections over that list — the real
  journal-fold projection (T7) is a separate, not-yet-built module; these
  helpers exist so tests (and the bless task) don't hand-roll `Enum`
  pipelines over `envelopes` everywhere.

  ## Two axes — never conflate them

  Every envelope carries two orthogonal positions:

    * **`body.id`** — the event's monotonic per-session id, i.e. the
      journal offset. This is the *seek/identity axis*: `attach`/`seek`
      commands, replay identity, and dedup/ordering semantics all key
      off it. Query it with `by_id/2`.
    * **`offset`** — the 1-based physical line in the fixture file.
      This is the *diagnostic axis*: where in the recorded stream a
      thing sits, what a `DecodeError` points at, what
      `pathologies/1` indexes. Query it with `from_offset/2`/`range/3`.

  In a well-formed stream they move in lockstep; in an adversarial one
  they deliberately diverge — id-reorder and duplicate-id corruptions
  are *detectable precisely because* the two axes disagree. A test that
  treats one as the other destroys that signal.
  """

  alias Raxol.Harness.Fixture.{Envelope, Header}

  @enforce_keys [:header, :envelopes, :path]
  defstruct [:header, :envelopes, :path]

  @type t :: %__MODULE__{
          header: Header.t(),
          envelopes: [Envelope.t()],
          path: Path.t()
        }

  @spec durable(t()) :: [Envelope.t()]
  def durable(%__MODULE__{envelopes: envelopes}) do
    Enum.filter(envelopes, &(&1.body.tier == :durable))
  end

  @spec ephemeral(t()) :: [Envelope.t()]
  def ephemeral(%__MODULE__{envelopes: envelopes}) do
    Enum.filter(envelopes, &(&1.body.tier == :ephemeral))
  end

  @spec by_family(t(), Raxol.Harness.Fixture.Event.family()) :: [Envelope.t()]
  def by_family(%__MODULE__{envelopes: envelopes}, family) do
    Enum.filter(envelopes, &(&1.body.family == family))
  end

  @spec by_type(t(), atom()) :: [Envelope.t()]
  def by_type(%__MODULE__{envelopes: envelopes}, type) do
    Enum.filter(envelopes, &(&1.body.type == type))
  end

  @doc "Envelopes at or after the given 1-based line offset (inclusive)."
  @spec from_offset(t(), pos_integer()) :: [Envelope.t()]
  def from_offset(%__MODULE__{envelopes: envelopes}, offset) do
    Enum.filter(envelopes, &(&1.offset >= offset))
  end

  @doc """
  Envelopes within the inclusive physical-line window
  `from..until` (the diagnostic axis — see the moduledoc).
  """
  @spec range(t(), pos_integer(), pos_integer()) :: [Envelope.t()]
  def range(%__MODULE__{envelopes: envelopes}, from, until) do
    Enum.filter(envelopes, &(&1.offset >= from and &1.offset <= until))
  end

  @doc """
  Envelopes whose `body.id` (journal offset — the seek/identity axis)
  equals `id`. Returns a list: in a well-formed stream it has at most
  one element, but adversarial streams carry duplicate ids on purpose,
  and surfacing both is exactly how a dedup test sees the corruption.
  """
  @spec by_id(t(), non_neg_integer()) :: [Envelope.t()]
  def by_id(%__MODULE__{envelopes: envelopes}, id) do
    Enum.filter(envelopes, &(&1.body.id == id))
  end

  @doc """
  The fixture's machine-readable corruption index (adversarial fixtures
  only; `[]` otherwise): a list of `%{class: String.t(), offset: pos_integer()}`
  read from the header's `pathologies` field. Downstream tests seek
  named corruptions instead of hardcoding line numbers:

      offset = Session.pathologies(session)
               |> Enum.find(&(&1.class == "late_delta_after_seal")).offset
  """
  @spec pathologies(t()) :: [Header.pathology()]
  def pathologies(%__MODULE__{header: %Header{pathologies: pathologies}}) do
    pathologies
  end

  @spec golden?(t()) :: boolean()
  def golden?(%__MODULE__{header: %Header{kind: :golden}}), do: true
  def golden?(%__MODULE__{}), do: false

  @spec adversarial?(t()) :: boolean()
  def adversarial?(%__MODULE__{header: %Header{kind: :adversarial}}), do: true
  def adversarial?(%__MODULE__{}), do: false
end
