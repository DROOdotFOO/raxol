defmodule Raxol.UI.Rendering.PaintAuthority do
  @moduledoc """
  The single seam both inline-render emit paths go through: the printed-
  history append path (T2b) and the pinned-viewport repaint path (T2c).

  Per `docs/proposals/in-flight/harness-ui-roadmap.md` §0 (D-PA) and
  `harness-ui-testing/02-renderer.md` §1b: "one owner module, both paths go
  through it." This behaviour is the CONTRACT that makes that true — T2b/T2c
  implement it against the real terminal (`IOAuthority`, below); tests drive
  it against `Raxol.Harness.Test.CaptureAuthority`, which records every emit
  as an origin-tagged entry instead of writing bytes. Because the tag layer
  is a property of the TEST double, not the behaviour, production callers pay
  nothing for it.

  Callback origins (mirrors `Raxol.Harness.Test.CaptureAuthority.Emit.origin`):

    * `append_sealed/2`   — `:seal`, T2b: append at the region's bottom line.
    * `repaint_footer/2`  — `:footer`, T2c: repaint the pinned footer rows.
    * `keyframe_footer/2` — `:keyframe`, T2c: Ctrl-L / resize footer redraw.
    * `with_cursor/3`     — `:cursor`, the save -> position -> emit -> restore
      bracket described in the roadmap's T2b spec; the sole owner of cursor
      save/restore so the two paths never race.
    * `resize/3`          — policy-bearing: behavior on resize is scoped by
      the D-PA verdict (seal-time-only / soft-owned / live-region-only, see
      the roadmap §0). This behaviour does not pick a policy; implementers
      do.
    * `region_top/1`      — the current split point `H - N` (number of rows
      in the scrolling history region; rows below it are the footer).

  This module intentionally carries NO implementation logic — it is the
  interface T2b/T2c build against and the test harness (TB) doubles. See
  `Raxol.Harness.Test.CaptureAuthority` for the recording test double and
  `Raxol.Harness.Test.SealOracle` for the assertions built on top of it.
  """

  @typedoc "Opaque authority state; each implementation defines its own shape."
  @type t :: term()

  @typedoc "Which pinned region a `with_cursor/3` bracket is positioning into."
  @type cursor_region :: :history | :footer

  @doc "Append sealed lines at the bottom of the scrolling history region."
  @callback append_sealed(t, iodata()) :: t

  @doc "Repaint some or all of the pinned footer (live tail + strip + composer)."
  @callback repaint_footer(t, iodata()) :: t

  @doc "Footer-only keyframe redraw (Ctrl-L recovery, resize). Never `\\e[2J`."
  @callback keyframe_footer(t, iodata()) :: t

  @doc """
  Runs `fun` under a save -> position-into-`region` -> ... -> restore cursor
  bracket. The single owner of the save/restore protocol; both `append_sealed`
  and `repaint_footer` paths must route cursor movement through this so saves
  and restores never interleave across paths (roadmap T2b: "cursor-ownership
  protocol... one owner module, both paths go through it").
  """
  @callback with_cursor(t, cursor_region(), (t -> t)) :: t

  @doc """
  Applies a resize. Policy-bearing per D-PA: what happens to already-sealed
  history on resize is an implementation decision bound by the T0 verdict,
  not by this behaviour. Implementations MUST emit their DECSTBM re-set
  (one `Dialect.region_set/2` per resize) through their own emit path, so
  INV-5's "re-set exactly once as `CSI 1;(h-N) r`" is byte-assertable.
  """
  @callback resize(t, width :: pos_integer(), height :: pos_integer()) :: t

  @doc "Current footer boundary: row count of the scrolling history region (`H - N`)."
  @callback region_top(t) :: pos_integer()

  defmodule Dialect do
    @moduledoc """
    The single home of the wire vocabulary shared by every `PaintAuthority`
    implementation: the cursor-save dialect and the scroll-region set. T2d's
    dialect decision (DECSC `\\e7`/`\\e8` vs SCO `\\e[s`/`\\e[u` — see
    `harness-ui-testing/02-renderer.md` open question 3) changes exactly the
    two constants below and nothing else; implementations and oracles must
    reference this module rather than embedding the bytes.

    DECSC is the provisional choice pending T2d.
    """

    @doc "Cursor save (DECSC, provisional pending T2d)."
    @spec cursor_save() :: binary()
    def cursor_save, do: "\e7"

    @doc "Cursor restore (DECRC, provisional pending T2d)."
    @spec cursor_restore() :: binary()
    def cursor_restore, do: "\e8"

    @doc "DECSTBM scroll-region set, 1-based inclusive rows: `CSI top;bottom r`."
    @spec region_set(pos_integer(), pos_integer()) :: binary()
    def region_set(top, bottom)
        when is_integer(top) and is_integer(bottom) and top >= 1 and
               bottom >= top do
      "\e[#{top};#{bottom}r"
    end

    @doc """
    Cursor Position (CUP), 1-based row, column pinned to `1`: `CSI row;1H`.
    The single byte-builder for "position at the start of history row
    `row`" -- callers that used to hand-roll `"\\e[\#{row};1H"` (the append
    path's `InlineAuthority.append_sealed/2`) route through this instead,
    so the wire format is defined once and pinned by test rather than
    duplicated per call site.
    """
    @spec cursor_position(pos_integer()) :: binary()
    def cursor_position(row) when is_integer(row) and row >= 1 do
      "\e[#{row};1H"
    end
  end

  defmodule IOAuthority do
    @moduledoc """
    Minimal production `PaintAuthority` stub: writes every emit straight to
    `IO.write/1` and otherwise just tracks dimensions. This is deliberately
    NOT a full T2b/T2c implementation — no scroll-region (DECSTBM) lifecycle,
    no D-PA-scoped resize policy, no real cursor-save dialect wiring (pending
    T2d, see `harness-ui-testing/02-renderer.md` open question 3). It exists
    so `Raxol.UI.Rendering.PaintAuthority` has at least one non-test
    implementation to compile against, and so the "tag layer costs nothing
    in prod" claim in the module doc is checkable: this module emits the
    same bytes `Raxol.Harness.Test.CaptureAuthority` records, minus the tags.

    T2b/T2c own filling this in for real (scroll region set/teardown,
    resize policy per D-PA, dialect-pinned cursor protocol).
    """

    @behaviour Raxol.UI.Rendering.PaintAuthority

    alias Raxol.UI.Rendering.PaintAuthority.Dialect

    @enforce_keys [:width, :height, :region_top]
    defstruct [:width, :height, :region_top]

    @type t :: %__MODULE__{
            width: pos_integer(),
            height: pos_integer(),
            region_top: pos_integer()
          }

    @doc "Builds a new authority state. `region_top` defaults to `height - 1` (a one-row footer)."
    @spec new(pos_integer(), pos_integer(), pos_integer() | nil) :: t()
    def new(width, height, region_top \\ nil) do
      %__MODULE__{
        width: width,
        height: height,
        region_top: region_top || max(height - 1, 1)
      }
    end

    @impl true
    def append_sealed(t, iodata) do
      IO.write(iodata)
      t
    end

    @impl true
    def repaint_footer(t, iodata) do
      IO.write(iodata)
      t
    end

    @impl true
    def keyframe_footer(t, iodata) do
      IO.write(iodata)
      t
    end

    @impl true
    def with_cursor(%__MODULE__{} = t, region, fun)
        when region in [:history, :footer] and is_function(fun, 1) do
      IO.write(Dialect.cursor_save())
      result = fun.(t)
      IO.write(Dialect.cursor_restore())
      result
    end

    @impl true
    def resize(%__MODULE__{} = t, width, height) do
      region_top = max(height - 1, 1)
      IO.write(Dialect.region_set(1, region_top))
      %{t | width: width, height: height, region_top: region_top}
    end

    @impl true
    def region_top(%__MODULE__{region_top: region_top}), do: region_top
  end
end
