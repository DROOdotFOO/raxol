defmodule Raxol.Terminal.Capabilities do
  @moduledoc """
  Session-immutable terminal capability record (F0 §5, T1 slice).

  Filled once at startup by the probe pass
  (`Raxol.Terminal.Capabilities.Probe` -> `Classifier`), cached in
  `:persistent_term`, and never mutated for the rest of the session.

  Provenance discipline: every detected capability records *where* the
  answer came from in `source` (`:decrqm`, `:xtversion`, `:xtgettcap`,
  `:env`, `:tmux_clamp`, `:default`). Env sniffing (`$TERM_PROGRAM` et
  al.) is only ever a free first-pass seed -- it can never claim a
  probe-able capability like mode 2026 (the fail-first anchor of the T1
  unit).

  `sync_output?/0` is the single public emit-gate for mode-2026 framing;
  render paths consult it and nothing else.
  """

  @type tier :: :core_minus | :core | :modern | :rich
  @type unicode_axis :: :none | :wide | :grapheme
  @type grapheme_width :: :mode_2027 | :measured | :assumed
  @type multiplexer :: :none | :tmux | :screen
  @type identity :: {String.t(), String.t() | nil} | nil
  @type rgb :: {0..255, 0..255, 0..255}
  @type color_depth :: :truecolor | :ansi256 | :ansi16 | :none
  @type polarity :: :dark | :light
  @type provenance ::
          :decrqm
          | :xtversion
          | :da1
          | :da2
          | :xtgettcap
          | :env
          | :tmux_clamp
          | :platform
          | :osc11
          | :osc10
          | :colorterm
          | :no_color
          | :term
          | :colorfgbg
          | :default

  @type t :: %__MODULE__{
          identity: identity(),
          tier: tier(),
          unicode: unicode_axis(),
          truecolor: boolean(),
          sixel: boolean(),
          sixel_regs: non_neg_integer() | nil,
          kitty_graphics: boolean(),
          kitty_keyboard: non_neg_integer() | nil,
          sync_output: boolean(),
          grapheme_width: grapheme_width(),
          in_band_resize: boolean(),
          lr_margins: boolean(),
          theme_events: boolean(),
          cell_px: {pos_integer(), pos_integer()} | nil,
          styled_underline: boolean(),
          multiplexer: multiplexer(),
          background: rgb() | nil,
          foreground: rgb() | nil,
          color_depth: color_depth(),
          polarity_seed: polarity() | nil,
          quirks: [atom()],
          source: %{optional(atom()) => provenance()}
        }

  defstruct identity: nil,
            tier: :core,
            unicode: :wide,
            truecolor: false,
            sixel: false,
            sixel_regs: nil,
            kitty_graphics: false,
            kitty_keyboard: nil,
            sync_output: false,
            grapheme_width: :assumed,
            in_band_resize: false,
            lr_margins: false,
            theme_events: false,
            cell_px: nil,
            styled_underline: false,
            multiplexer: :none,
            background: nil,
            foreground: nil,
            color_depth: :ansi16,
            polarity_seed: nil,
            quirks: [],
            source: %{}

  @record_key {__MODULE__, :record}
  @mode_key {__MODULE__, :mode_replies}

  # ---- session cache (:persistent_term, write-once) ----

  @doc """
  Caches the classified record for the session. Write-once: the first
  cached record wins; later calls are no-ops (session immutability,
  CAP-P-13).
  """
  @spec cache(t()) :: :ok
  def cache(%__MODULE__{} = caps) do
    case :persistent_term.get(@record_key, :undefined) do
      :undefined -> :persistent_term.put(@record_key, caps)
      _existing -> :ok
    end
  end

  @doc "Returns the cached session record, if any."
  @spec cached() :: {:ok, t()} | :error
  def cached do
    case :persistent_term.get(@record_key, :undefined) do
      :undefined -> :error
      %__MODULE__{} = caps -> {:ok, caps}
    end
  end

  @doc """
  THE mode-2026 emit gate. Render paths consult this one function before
  emitting `CSI ? 2026 h/l` sync frames.

  Truth order: cached session record -> raw DECRQM mode replies noted by
  the driver's reply scan -> `false`. Env is never consulted.
  """
  @spec sync_output?() :: boolean()
  def sync_output? do
    case cached() do
      {:ok, caps} ->
        caps.sync_output

      :error ->
        Map.get(mode_replies(), 2026) in [1, 2]
    end
  end

  @doc false
  @spec note_mode_reply(non_neg_integer(), integer() | nil) :: :ok
  def note_mode_reply(mode, value) when is_integer(mode) do
    replies = :persistent_term.get(@mode_key, %{})
    :persistent_term.put(@mode_key, Map.put_new(replies, mode, value))
  end

  @doc false
  @spec mode_replies() :: %{optional(non_neg_integer()) => integer() | nil}
  def mode_replies, do: :persistent_term.get(@mode_key, %{})

  @doc false
  @spec reset_cache() :: :ok
  def reset_cache do
    :persistent_term.erase(@record_key)
    :persistent_term.erase(@mode_key)
    :ok
  end

  # ---- native-palette-riding detection-seam readers (pure, no I/O) ----
  #
  # Wire bytes only: raw {r,g,b} from OSC 11/10, the classified color
  # depth, and the $COLORFGBG polarity SEED. Deliberately no OKLab/OKLCH
  # math, no computed ground lightness, no final polarity decision --
  # that color science lives in main raxol's Salience module. Nil-safe
  # when no record has been cached yet (headless, tests).

  @doc "Detected native background color (`OSC 11`), if any."
  @spec background() :: rgb() | nil
  def background do
    case cached() do
      {:ok, caps} -> caps.background
      :error -> nil
    end
  end

  @doc "Detected native foreground color (`OSC 10`), if any."
  @spec foreground() :: rgb() | nil
  def foreground do
    case cached() do
      {:ok, caps} -> caps.foreground
      :error -> nil
    end
  end

  @doc """
  The classified color depth. Defaults to `:ansi16` (the Core floor) when
  no record has been cached, mirroring the struct default.
  """
  @spec color_depth() :: color_depth()
  def color_depth do
    case cached() do
      {:ok, caps} -> caps.color_depth
      :error -> :ansi16
    end
  end

  @doc """
  The `$COLORFGBG` polarity SEED (`:dark` | `:light` | `nil`). A seed
  only -- used downstream iff OSC 11 is silent (native-palette-riding §2
  rung 2).
  """
  @spec polarity_seed() :: polarity() | nil
  def polarity_seed do
    case cached() do
      {:ok, caps} -> caps.polarity_seed
      :error -> nil
    end
  end
end
