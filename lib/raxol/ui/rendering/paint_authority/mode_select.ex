defmodule Raxol.UI.Rendering.PaintAuthority.ModeSelect do
  @moduledoc """
  T3's startup mode-pick decision: caps + env -> which `PaintAuthority`
  profile a session renders through
  (`docs/proposals/in-flight/harness-ui-roadmap.md`, unit T3 —
  "degradation ladder").

  This is a PURE function. It never calls `System.get_env/1` or does any
  I/O itself -- callers (T13a's assembler, or a `mix run` entry point) are
  responsible for gathering the env map and passing it in, exactly the
  same discipline `Raxol.Terminal.Capabilities.Classifier.classify/3`
  already uses for its own env seed (`04-capability.md`: "env sniffing is
  only ever a free first-pass seed"). Keeping the decision pure is what
  makes the full mode-pick matrix table-testable without a pty or a real
  tmux session.

  ## The three tiers

    * `:inline_log` — the default: `InlineAuthority` (T2b/T2c), full
      DECSTBM-pinned footer + scrolling history.
    * `:tmux_conservative` — NOT a separate authority module. Per the
      roadmap: "tmux tier per T0: no OSC marks assumed consumed, clamped
      caps, possibly transient-region algorithm." T1's capability ladder
      already clamps `%Capabilities{}` for a detected multiplexer before
      it ever reaches `InlineAuthority.new/5` (`reflow_capable?/1` is
      conservatively `false` for anything that isn't measured, and tmux is
      never on that allowlist); `ModeSelect` only picks the TIER NAME so a
      caller knows to route through that same `InlineAuthority` with the
      already-clamped capability record it fetched from `Capabilities`.
      There is no `TmuxConservativeAuthority` module and this unit does
      not add one.
    * `:flat` — `FlatAuthority` (this unit, sibling module): append-only,
      zero regions, zero cursor jumps. The screen-reader answer, the
      CI/pipe answer, the block-hater answer (AD-U2).

  ## Rule order (first match wins)

  1. **Explicit env override** (`RAXOL_HARNESS_MODE=flat|tmux|inline`)
     wins over every other signal, including a degenerate terminal or a
     detected multiplexer -- an operator who typed the override gets
     exactly what they asked for.
  2. **Headless** (`TERM=dumb`, not a tty, or `CI` truthy AND not a tty)
     -> `:flat`. This has to run before the tmux check: a CI runner
     piping output through `TERM=dumb` (or no tty at all) is not a place
     any cursor-positioning tier belongs, tmux-flavored or not.
  3. **Degenerate geometry** (`ScrollRegionManager.degenerate?/2`: the
     terminal is too short to hold a footer plus a 1-row history region)
     -> `:flat`.
  4. **tmux/screen multiplexer detected** -> `:tmux_conservative`.
  5. Otherwise -> `:inline_log`.

  ### Why degenerate geometry is checked before tmux (rules 3 vs. 4)

  This ordering is load-bearing, not cosmetic: a degenerate geometry
  (too few rows to hold a footer plus a 1-row history region, e.g.
  `rows: 2, footer_rows: 2`) means `ScrollRegionManager` cannot carve out
  a real history region, so `region_top` pins at row 1. Every subsequent
  `InlineAuthority` seal then issues its append CUP to that same pinned
  row 1 BEFORE the terminal has scrolled -- each new block overwrites the
  previous one instead of accumulating (traced on real bytes: `\e[1;1HL1...`
  then `\e[1;1HM1...`, with `L1` clobbered, never reaching scrollback).
  This happens whether or not the session is also inside tmux: tmux's
  clamped capability profile changes which escape sequences
  `InlineAuthority` is willing to assume are honored, but it does nothing
  to fix a `region_top` that is pinned at 1 by the geometry itself. So a
  session that is BOTH degenerate AND tmux-detected still gets the
  clobbering append path if routed to `:tmux_conservative` -- there is no
  additional safety purchased by keeping the tmux-specific clamping, only
  a broken transcript. `:flat` sidesteps the whole failure mode: it never
  positions a cursor, so there is no pinned row to clobber, and every
  sealed line survives in order. That is strictly safer than any
  cursor-positioning tier at degenerate geometry, which is why degenerate
  geometry outranks tmux detection in the rule order. A tmux session with
  ADEQUATE geometry has no such pinning problem and keeps its
  `:tmux_conservative` tier as before.
  """

  alias Raxol.Terminal.Capabilities
  alias Raxol.Terminal.ScrollRegionManager

  @typedoc "Which `PaintAuthority` tier a session should render through."
  @type mode :: :inline_log | :tmux_conservative | :flat

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
      (`N` in the roadmap's `H - N` split). Defaults to `0`.

  Never consults `System.get_env/1`, `:persistent_term`, or any device —
  purely a function of its three arguments.
  """
  @spec select(Capabilities.t() | nil, env(), keyword()) :: mode()
  def select(caps, env, opts \\ []) when is_map(env) and is_list(opts) do
    case override(env) do
      nil -> select_without_override(caps, env, opts)
      mode -> mode
    end
  end

  defp select_without_override(caps, env, opts) do
    cond do
      headless?(env) -> :flat
      degenerate_geometry?(opts) -> :flat
      tmux?(caps, env) -> :tmux_conservative
      true -> :inline_log
    end
  end

  # ---- rule 1: explicit override ----

  defp override(env) do
    case Map.get(env, "RAXOL_HARNESS_MODE") do
      "flat" -> :flat
      "tmux" -> :tmux_conservative
      "inline" -> :inline_log
      _other -> nil
    end
  end

  # ---- rule 2: headless (TERM=dumb / non-tty / CI-without-tty) ----

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

  # ---- rule 4: tmux/screen multiplexer ----

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

  # ---- rule 3: degenerate geometry ----

  defp degenerate_geometry?(opts) do
    case Keyword.get(opts, :rows) do
      rows when is_integer(rows) and rows > 0 ->
        footer_rows = Keyword.get(opts, :footer_rows, 0)
        ScrollRegionManager.degenerate?(rows, footer_rows)

      _other ->
        false
    end
  end
end
