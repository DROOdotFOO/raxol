defmodule Raxol.UI.Rendering.PaintAuthority.ModeSelect do
  @moduledoc """
  The degradation ladder's startup mode-pick decision: caps + env ->
  which `PaintAuthority` profile a session renders through.

  This is a PURE function. It never calls `System.get_env/1` or does any
  I/O itself -- callers (the assembled harness's assembler, or a `mix run`
  entry point) are responsible for gathering the env map and passing it
  in, exactly the same discipline
  `Raxol.Terminal.Capabilities.Classifier.classify/3` already uses for its
  own env seed (env sniffing is only ever a free first-pass seed). Keeping
  the decision pure is what makes the full mode-pick matrix table-testable
  without a pty or a real tmux session.

  ## The three tiers

    * `:inline_log` — the default: `InlineAuthority` (the append path +
      the footer viewport), full DECSTBM-pinned footer + scrolling
      history.
    * `:tmux_conservative` — NOT a separate authority module. The tmux
      tier assumes no OSC marks are consumed, clamps caps, and possibly
      uses a transient-region algorithm; the capability ladder already
      clamps `%Capabilities{}` for a detected multiplexer before it ever
      reaches `InlineAuthority.new/5` (`reflow_capable?/1` is
      conservatively `false` for anything that isn't measured, and tmux is
      never on that allowlist); `ModeSelect` only picks the TIER NAME so a
      caller knows to route through that same `InlineAuthority` with the
      already-clamped capability record it fetched from `Capabilities`.
      There is no `TmuxConservativeAuthority` module and this unit does
      not add one.
    * `:flat` — `FlatAuthority` (this unit, sibling module): append-only,
      zero regions, zero cursor jumps. The screen-reader answer, the
      CI/pipe answer, the block-hater answer.

  ## Rule order

  Mode-pick happens in two passes: first a CANDIDATE mode is resolved
  (from an explicit override or from auto-detection), then a
  degenerate-geometry FLOOR is applied to whatever that candidate is.
  The floor runs LAST, after the candidate is chosen, not as one more
  item in the override/auto-detect priority list -- see "Why the
  degenerate floor applies after override resolution" below for why that
  distinction is load-bearing.

  ### Pass 1: resolve a candidate mode

  1. **Explicit env override** (`RAXOL_HARNESS_MODE=flat|tmux|inline`,
     case- and whitespace-insensitive) is the candidate, when recognized.
     An unrecognized non-empty value does NOT win -- it falls through to
     auto-detection below, and is surfaced separately via
     `select_with_reason/3`'s `:override_unrecognized` reason so a caller
     can warn instead of silently guessing what the operator meant.
  2. Otherwise, auto-detect:
     a. **Headless** (`TERM=dumb`, not a tty, or `CI` truthy AND not a
        tty) -> `:flat`. This has to run before the tmux check: a CI
        runner piping output through `TERM=dumb` (or no tty at all) is
        not a place any cursor-positioning tier belongs, tmux-flavored
        or not.
     b. **tmux/screen multiplexer detected** -> `:tmux_conservative`.
     c. Otherwise -> `:inline_log`.

  ### Pass 2: the degenerate-geometry floor

  **Degenerate geometry** (`ScrollRegionManager.degenerate?/2`: the
  terminal is too short to hold a footer plus a 1-row history region)
  clamps ANY non-`:flat` candidate down to `:flat`, regardless of whether
  that candidate came from an override or from auto-detection. A
  candidate that is already `:flat` (override or auto-detected) is left
  alone -- the floor is a one-way clamp, never a way to escape `:flat`.

  ### Why the degenerate floor applies after override resolution

  This ordering is load-bearing, not cosmetic: a degenerate geometry
  (too few rows to hold a footer plus a 1-row history region, e.g.
  `rows: 2, footer_rows: 2`) means `ScrollRegionManager` cannot carve out
  a real history region, so `region_top` pins at row 1. Every subsequent
  `InlineAuthority` seal then issues its append CUP to that same pinned
  row 1 BEFORE the terminal has scrolled -- each new block overwrites the
  previous one instead of accumulating (traced on real bytes: `\e[1;1HL1...`
  then `\e[1;1HM1...`, with `L1` clobbered, never reaching scrollback).

  That clobber has nothing to do with WHY `InlineAuthority` was picked --
  it fires identically whether the route there was auto-detected tmux
  (this unit's original regression: a tmux-detected session at degenerate
  geometry must not fall through to `:tmux_conservative`, since that tier
  still reaches the same clobbering `InlineAuthority` append path) or an
  operator-supplied `RAXOL_HARNESS_MODE=inline`/`=tmux` override picked
  the same authority explicitly. An override that special-cased itself to
  skip the floor would reproduce the EXACT byte-traced clobber above,
  just reached via an exported env var instead of auto-detection --
  there is no additional safety purchased by letting an override outrank
  the floor, only a broken transcript once the geometry turns out to be
  degenerate at runtime (which the operator setting the override at
  shell-startup time cannot always know in advance). `:flat` sidesteps
  the whole failure mode: it never positions a cursor, so there is no
  pinned row to clobber, and every sealed line survives in order. That is
  strictly safer than any cursor-positioning tier at degenerate geometry,
  for a candidate reached by ANY path, which is why the floor applies
  uniformly AFTER candidate resolution rather than being folded into the
  override-vs-auto-detect priority order. A `:flat` override is always
  honored -- it is already the floor's own target, so clamping is a
  no-op -- and a session with ADEQUATE geometry has no pinning problem and
  keeps whatever candidate it resolved to (override or auto-detected) as
  before.
  """

  alias Raxol.Terminal.Capabilities
  alias Raxol.Terminal.ScrollRegionManager

  @typedoc "Which `PaintAuthority` tier a session should render through."
  @type mode :: :inline_log | :tmux_conservative | :flat

  @typedoc """
  Why `select_with_reason/3` picked the mode it returned:

    * `:override` — a recognized `RAXOL_HARNESS_MODE` value was honored
      as-is (or was already `:flat`, so the degenerate floor was a no-op).
    * `:override_unrecognized` — `RAXOL_HARNESS_MODE` was set to a
      non-empty value that isn't `flat`/`tmux`/`inline` (after
      trim+downcase); the mode fell through to auto-detection.
    * `:headless` — auto-detected via `TERM=dumb` / non-tty / CI-without-tty.
    * `:tmux` — auto-detected via a `TMUX`/`screen`-prefixed `TERM` env var
      or a `Capabilities.multiplexer` of `:tmux`/`:screen`.
    * `:default` — auto-detection fell through to the `:inline_log` default.
    * `:degenerate_clamp` — the degenerate-geometry floor overrode
      whatever candidate the above resolved to (see moduledoc).
  """
  @type reason ::
          :override
          | :override_unrecognized
          | :headless
          | :tmux
          | :default
          | :degenerate_clamp

  @typedoc """
  Pre-gathered environment facts. String keys mirror OS env var names
  (`System.get_env/0`'s shape) verbatim so callers can pass that map
  through with no translation. `:tty?` is the one non-OS-env key: real
  tty detection is an I/O call, not a pure fact, so it is the caller's
  job to determine it (e.g. via `:io.columns/0`/`:file.isatty` or a
  driver-level flag) and thread the answer in here.
  """
  @type env :: %{
          optional(String.t()) => String.t() | nil,
          optional(:tty?) => boolean()
        }

  @doc """
  Picks the render mode. `opts` carries geometry for the degenerate-
  terminal check:

    * `:rows` — total terminal rows (integer). Omit when geometry is
      unknown (e.g. before the first resize event) — the degenerate
      check is then skipped (treated as non-degenerate), matching every
      other rule's fail-open-to-`:inline_log` default.
    * `:footer_rows` — the footer row count the caller intends to pin
      (`N` in the `H - N` split). Defaults to `0`. A negative
      or non-integer value is also treated as fail-open-to-non-degenerate
      rather than raised — `ScrollRegionManager.degenerate?/2` itself
      guards `footer_rows >= 0`, so this module has to guard the same
      thing before delegating, or a caller-supplied `footer_rows: -1`
      would crash mode-pick instead of degrading gracefully.

  Never consults `System.get_env/1`, `:persistent_term`, or any device —
  purely a function of its three arguments. Delegates to
  `select_with_reason/3` and discards the reason; use that function
  directly when the reason is needed (e.g. a startup notice explaining
  WHY a session ended up in `:flat`).
  """
  @spec select(Capabilities.t() | nil, env(), keyword()) :: mode()
  def select(caps, env, opts \\ []) when is_map(env) and is_list(opts) do
    {mode, _reason} = select_with_reason(caps, env, opts)
    mode
  end

  @doc """
  Same mode-pick as `select/3`, plus the `reason()` the pick came from
  (see the `t:reason/0` typedoc). This is the seam the assembled harness's
  assembler uses to print a startup notice ("routing through :flat
  because geometry is too small for a footer" and similar).
  """
  @spec select_with_reason(Capabilities.t() | nil, env(), keyword()) ::
          {mode(), reason()}
  def select_with_reason(caps, env, opts \\ [])
      when is_map(env) and is_list(opts) do
    caps
    |> resolve_candidate(env)
    |> apply_degenerate_floor(opts)
  end

  # ---- pass 1: resolve the candidate mode (override, else auto-detect) ----

  defp resolve_candidate(caps, env) do
    case override(env) do
      {:ok, mode} -> {mode, :override}
      :unrecognized -> {auto_detect_mode(caps, env), :override_unrecognized}
      :none -> auto_detect(caps, env)
    end
  end

  defp auto_detect_mode(caps, env) do
    {mode, _reason} = auto_detect(caps, env)
    mode
  end

  defp auto_detect(caps, env) do
    cond do
      headless?(env) -> {:flat, :headless}
      tmux?(caps, env) -> {:tmux_conservative, :tmux}
      true -> {:inline_log, :default}
    end
  end

  # ---- pass 2: degenerate-geometry floor (see moduledoc) ----

  defp apply_degenerate_floor({:flat, reason}, _opts), do: {:flat, reason}

  defp apply_degenerate_floor({mode, reason}, opts) do
    if degenerate_geometry?(opts) do
      {:flat, :degenerate_clamp}
    else
      {mode, reason}
    end
  end

  # ---- explicit override: recognized value, unrecognized, or absent ----
  # Values are trimmed and downcased before matching, so `Flat`/` flat `
  # both match `flat`.

  defp override(env) do
    case Map.get(env, "RAXOL_HARNESS_MODE") do
      nil ->
        :none

      "" ->
        :none

      raw ->
        override_normalized(
          raw
          |> to_string()
          |> String.trim()
          |> String.downcase()
        )
    end
  end

  defp override_normalized(""), do: :none
  defp override_normalized("flat"), do: {:ok, :flat}
  defp override_normalized("tmux"), do: {:ok, :tmux_conservative}
  defp override_normalized("inline"), do: {:ok, :inline_log}
  defp override_normalized(_other), do: :unrecognized

  # ---- headless (TERM=dumb / non-tty / CI-without-tty) ----

  defp headless?(env) do
    dumb_term?(env) or non_tty?(env) or ci_without_tty?(env)
  end

  defp dumb_term?(env), do: Map.get(env, "TERM") == "dumb"

  defp non_tty?(env), do: Map.get(env, :tty?, true) == false

  defp ci_without_tty?(env), do: truthy?(Map.get(env, "CI")) and non_tty?(env)

  defp truthy?(nil), do: false
  defp truthy?(""), do: false
  defp truthy?("false"), do: false
  defp truthy?("0"), do: false
  defp truthy?(_other), do: true

  # ---- tmux/screen multiplexer ----

  defp tmux?(caps, env), do: tmux_env?(env) or multiplexer_detected?(caps)

  defp tmux_env?(env) do
    present?(env, "TMUX") or term_prefix?(env, "screen") or
      term_prefix?(env, "tmux")
  end

  defp term_prefix?(env, prefix) do
    env |> Map.get("TERM", "") |> to_string() |> String.starts_with?(prefix)
  end

  defp present?(env, key) do
    case Map.get(env, key) do
      nil -> false
      "" -> false
      _other -> true
    end
  end

  defp multiplexer_detected?(%Capabilities{multiplexer: multiplexer}),
    do: multiplexer in [:tmux, :screen]

  defp multiplexer_detected?(_caps), do: false

  # ---- degenerate geometry (the pass-2 floor) ----
  #
  # Fails open to `false` (non-degenerate) whenever `:rows`/`:footer_rows`
  # aren't the shape `ScrollRegionManager.degenerate?/2` itself requires
  # (`rows` a positive integer, `footer_rows` a non-negative integer) --
  # matching every other rule's fail-open default rather than raising a
  # `FunctionClauseError` on a caller-supplied `footer_rows: -1`.
  defp degenerate_geometry?(opts) do
    with rows when is_integer(rows) and rows > 0 <- Keyword.get(opts, :rows),
         footer_rows when is_integer(footer_rows) and footer_rows >= 0 <-
           Keyword.get(opts, :footer_rows, 0) do
      ScrollRegionManager.degenerate?(rows, footer_rows)
    else
      _other -> false
    end
  end
end
