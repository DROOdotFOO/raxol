defmodule Raxol.Harness.Test.CaptureAuthority do
  @moduledoc """
  Test double for `Raxol.UI.Rendering.PaintAuthority`. Records every emit as
  an ordered, origin-tagged `%Emit{}` plus a concatenated `raw` mirror — the
  ground truth every byte-level property/oracle asserts against (per
  `harness-ui-testing/02-renderer.md` §1b).

  The origin tag is recorded FROM THE CALL SITE (which behaviour callback was
  invoked), never reverse-engineered from the bytes — that is what makes
  "which path emitted this byte" a fact instead of an inference, and is the
  whole point of building this double instead of pattern-matching `raw`.
  """

  @behaviour Raxol.UI.Rendering.PaintAuthority

  alias Raxol.UI.Rendering.PaintAuthority.Dialect

  defmodule Emit do
    @moduledoc "One origin-tagged emission, in the order it was recorded."

    @enforce_keys [:origin, :bytes, :seq]
    defstruct [:origin, :bytes, :seq]

    @type origin :: :seal | :footer | :keyframe | :cursor | :region
    @type t :: %__MODULE__{
            origin: origin(),
            bytes: binary(),
            seq: non_neg_integer()
          }
  end

  @enforce_keys [:width, :height, :region_top]
  defstruct width: 80,
            height: 24,
            region_top: 23,
            log: [],
            raw: "",
            next_seq: 0,
            in_cursor_bracket: false

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          region_top: pos_integer(),
          log: [Emit.t()],
          raw: binary(),
          next_seq: non_neg_integer(),
          in_cursor_bracket: boolean()
        }

  @doc "Builds a fresh capture state. `region_top` defaults to `height - 1` (one footer row)."
  @spec new(pos_integer(), pos_integer(), pos_integer() | nil) :: t()
  def new(width, height, region_top \\ nil) do
    %__MODULE__{
      width: width,
      height: height,
      region_top: region_top || max(height - 1, 1)
    }
  end

  @doc "The ordered log of tagged emits, oldest first."
  @spec log(t()) :: [Emit.t()]
  def log(%__MODULE__{log: log}), do: Enum.reverse(log)

  @doc "Concatenated raw byte stream, in emission order — the O1/O2 oracle input."
  @spec raw(t()) :: binary()
  def raw(%__MODULE__{raw: raw}), do: raw

  @doc "Only the emits whose origin is `origin`, oldest first."
  @spec log_by_origin(t(), Emit.origin()) :: [Emit.t()]
  def log_by_origin(%__MODULE__{} = t, origin) do
    t |> log() |> Enum.filter(&(&1.origin == origin))
  end

  @impl true
  def append_sealed(%__MODULE__{} = t, iodata), do: record(t, :seal, iodata)

  @impl true
  def repaint_footer(%__MODULE__{} = t, iodata), do: record(t, :footer, iodata)

  @impl true
  def keyframe_footer(%__MODULE__{} = t, iodata),
    do: record(t, :keyframe, iodata)

  @impl true
  def with_cursor(%__MODULE__{in_cursor_bracket: true}, _region, _fun) do
    raise ArgumentError,
          "nested with_cursor: the cursor-save slot is single-owner " <>
            "(one DECSC register per terminal) — a bracket inside a " <>
            "bracket silently clobbers the outer saved position and is " <>
            "always a bug"
  end

  def with_cursor(%__MODULE__{} = t, region, fun)
      when region in [:history, :footer] and is_function(fun, 1) do
    # Save/restore bytes come from the shared Dialect (DECSC provisional
    # pending T2d), tagged `:cursor` so callers can distinguish
    # cursor-protocol bytes from content bytes.
    %{t | in_cursor_bracket: true}
    |> record(:cursor, Dialect.cursor_save())
    |> fun.()
    |> Map.put(:in_cursor_bracket, false)
    |> record(:cursor, Dialect.cursor_restore())
  end

  @impl true
  def resize(%__MODULE__{} = t, width, height) do
    region_top = max(height - 1, 1)

    # The DECSTBM re-set goes through the same capture path as every other
    # emit, so INV-5's "re-set exactly once per resize" is byte-assertable.
    record(
      %{t | width: width, height: height, region_top: region_top},
      :region,
      Dialect.region_set(1, region_top)
    )
  end

  @impl true
  def region_top(%__MODULE__{region_top: region_top}), do: region_top

  defp record(%__MODULE__{} = t, origin, iodata) do
    bytes = IO.iodata_to_binary(iodata)
    emit = %Emit{origin: origin, bytes: bytes, seq: t.next_seq}

    %{t | log: [emit | t.log], raw: t.raw <> bytes, next_seq: t.next_seq + 1}
  end
end
