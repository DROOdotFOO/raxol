defmodule Raxol.UI.Rendering.PaintAuthority.FlatAuthority do
  @moduledoc """
  T3's `:flat` tier: the append-only, zero-region, zero-cursor-jump
  `PaintAuthority` implementation
  (`docs/proposals/in-flight/harness-ui-roadmap.md`, unit T3 —
  "degradation ladder"). Picked by
  `Raxol.UI.Rendering.PaintAuthority.ModeSelect.select/3` for `TERM=dumb`,
  non-tty, CI-without-tty, and degenerate-geometry sessions — the
  screen-reader answer, the CI/pipe answer, the block-hater answer (AD-U2).

  ## The SGR/escape decision: zero escape bytes, enforced IN THIS MODULE

  Unlike `InlineAuthority` (which never emits a full clear but DOES emit
  DECSTBM/CUP/cursor-save bytes) this module never writes ANY byte in the
  C0 control range (`0x00`-`0x1F`, which includes `0x1B`/ESC) except
  `\\t`, `\\r`, `\\n` — not just cursor movement, but also SGR styling and
  bare control bytes like BEL. This is a deliberate v1 simplification, not
  an oversight, AND it is a property `append_sealed/2` enforces itself by
  scrubbing those bytes out of the iodata before it ever reaches the
  device — it is not a contract callers have to uphold on their own.
  Content flowing into this authority can originate from an LLM response,
  a tool's stdout, or any other untrusted source; a caller forgetting to
  sanitize it must not be able to smuggle a screen clear or a color
  change through the flat tier.

    * A conditionally-styled flat mode (SGR when the destination happens
      to be a real tty, plain when it's a genuine pipe) would need its
      own tty-detection seam threaded into the AUTHORITY itself, when
      `ModeSelect` already computed that exact fact once, at startup, to
      pick `:flat` in the first place. Re-deriving it a second time inside
      the authority (or plumbing the `:tty?` flag through as authority
      state) is more machinery than a v1 flat writer needs.
    * Zero escape bytes is also the easiest claim to make PROVABLY true:
      the mechanical acceptance check ("flat output contains no
      cursor-move/CUP/scroll sequences") reduces to "every scanned token
      is `{:text, _}`" with no exceptions to special-case for allowed SGR
      runs — and now that the scrub happens inside the module, that
      property holds regardless of what a caller passes in, not just for
      well-behaved callers.
    * Scrubbing the ESC lead byte and leaving the rest of a hostile
      sequence's bytes untouched (e.g. `\\e[31m` becomes the visible
      fragment `[31m`) is an intentional, HONEST failure mode: a reader
      sees garbled-looking text and knows something was stripped. The
      alternative — swallowing the whole sequence body, or worse, leaving
      it byte-for-byte intact — risks an invisible injection that changes
      what a downstream pipe or screen reader does without any visible
      trace. A visible fragment is strictly safer than a silent one.
    * This is additive, not a rewrite, to upgrade later: a future unit
      that wants styled flat output for a genuine tty destination can
      thread `ModeSelect`'s already-computed `:tty?` fact into `new/3` as
      an opt-in flag and add SGR emission ONLY on that path, without
      touching the append-only/no-region/no-cursor contract this module
      ships today.

  ## Line-terminator convention: plain `\\n`

  `InlineAuthority.seal/2` requires `\\r\\n`-terminated content because a
  real terminal in raw mode needs the explicit carriage return (output
  translation is off). `:flat`'s destination is a pipe, a log file, a
  screen reader, or a CI capture buffer — none of which need or want the
  extra `\\r`. Callers building content for `FlatAuthority` should
  terminate each line with plain `\\n`. This module does not enforce or
  rewrite terminators itself — `\\t`, `\\r`, and `\\n` are all exempt from
  the C0 scrub described above, so both conventions pass through
  unchanged (exactly like `PaintAuthority.IOAuthority`'s minimal-stub
  convention for everything outside that scrub) — the `\\r\\n` vs. `\\n`
  choice lives entirely in what the CALLER passes in, so a caller that
  already has `\\r\\n`-terminated content (e.g. replaying the same
  fixture through both tiers for a parity check) gets it written through
  unchanged rather than silently rewritten.

  ## What every callback does

    * `append_sealed/2` — scrubs C0 control bytes (except `\\t`/`\\r`/`\\n`)
      out of `iodata`, then writes what remains. No CUP, ever.
    * `repaint_footer/2` / `keyframe_footer/2` — NO-OP (return state
      unchanged, write nothing). Flat has no footer to repaint or
      keyframe; a caller that calls these on a flat authority gets
      silence, not stray bytes.
    * `with_cursor/3` — runs `fun` directly against the state. No save,
      no restore: there is no cursor position worth protecting when
      nothing ever moves it.
    * `resize/3` — updates the tracked `width`/`height` but writes zero
      bytes. There is no region to re-pin.
    * `region_top/1` — returns `height`: with no footer carved out, the
      entire screen is (conceptually) history/content.
  """

  @behaviour Raxol.UI.Rendering.PaintAuthority

  @enforce_keys [:device, :width, :height]
  defstruct [:device, :width, :height]

  @type t :: %__MODULE__{
          device: IO.device(),
          width: pos_integer(),
          height: pos_integer()
        }

  @doc "Builds a new flat authority state. No device writes happen at construction."
  @spec new(IO.device(), pos_integer(), pos_integer()) :: t()
  def new(device, width, height)
      when is_integer(width) and width > 0 and is_integer(height) and
             height > 0 do
    %__MODULE__{device: device, width: width, height: height}
  end

  @doc """
  Sugar mirroring `InlineAuthority.seal/2`'s call shape so a caller can
  swap authorities without changing its call site: `seal/2` is exactly
  `append_sealed/2` here (no cursor bracket to wrap it in).
  """
  @spec seal(t(), iodata()) :: t()
  def seal(%__MODULE__{} = t, iodata), do: append_sealed(t, iodata)

  @impl true
  def append_sealed(%__MODULE__{device: device} = t, iodata) do
    IO.write(device, scrub(iodata))
    t
  end

  # Module-enforced escape scrub (see moduledoc): strips every C0 control
  # byte (0x00-0x1F, which includes ESC/0x1B) except `\t`/`\r`/`\n`.
  # Byte-wise stripping is safe for UTF-8 content: multi-byte sequence
  # lead bytes (0xC2-0xF4) and continuation bytes (0x80-0xBF) are both
  # outside the C0 range, so no valid UTF-8 codepoint is ever split.
  @c0_exceptions [?\t, ?\r, ?\n]

  defp scrub(iodata) do
    for <<byte <- IO.iodata_to_binary(iodata)>>,
        byte >= 0x20 or byte in @c0_exceptions,
        into: <<>>,
        do: <<byte>>
  end

  @impl true
  def repaint_footer(%__MODULE__{} = t, _iodata), do: t

  @impl true
  def keyframe_footer(%__MODULE__{} = t, _iodata), do: t

  @impl true
  def with_cursor(%__MODULE__{} = t, region, fun)
      when region in [:history, :footer] and is_function(fun, 1) do
    fun.(t)
  end

  @impl true
  def resize(%__MODULE__{} = t, width, height)
      when is_integer(width) and width > 0 and is_integer(height) and
             height > 0 do
    %{t | width: width, height: height}
  end

  @impl true
  def region_top(%__MODULE__{height: height}), do: height
end
