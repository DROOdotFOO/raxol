defmodule Raxol.UI.Components.Harness.AxolFace do
  @moduledoc """
  The axol face `≡··≡` — the harness identity/status layer.

  A fixed four-display-column glyph: the gills (`≡`) are constant, the two
  eyes carry the agent's state. The face swaps in place, no width jitter,
  so it can sit in a status strip and never disturb layout.

  ## States

  | State | Cycle | Motif |
  |---|---|---|
  | `:boot` | `≡--≡` → `≡··≡` → `≡oo≡` → `≡··≡` | wake blink |
  | `:idle` | `≡··≡` … `≡--≡` | neutral, slow blink |
  | `:thinking` | `≡··≡` → `≡''≡` → `≡..≡` | eyes drift |
  | `:working` | `≡oo≡` → `≡OO≡` | pupils pulse |
  | `:done` | `≡^^≡` | happy squint |
  | `:error` | `≡xx≡` | knocked-out eyes |

  The state maps directly from harness contract events (see
  `Raxol.UI.Components.Harness.AxolFace` usage in the `mix raxol.code`
  surface): `turn_started` → `:thinking`, tool activity → `:working`,
  `turn_completed{final}` → `:done`, `error` → `:error`, otherwise
  `:idle`. Frame advance is event-driven (bump on each `item_delta`) or a
  subscription tick.

  ## Single source of truth

  `glyph/3` is a pure function of `(state, frame, ascii?)` so every
  surface — the CLI boot beat, this TUI component, an SSE status line —
  renders the identical face. `ascii?: true` selects an ASCII-only
  fallback (gills `=`, ASCII eyes) for terminals without a UTF-8 font;
  the branded `≡` face is the default (it is single display-width and
  renders in modern terminals).
  """

  alias Raxol.UI.Components.Harness.Ids
  alias Raxol.UI.StyleHelper

  use Raxol.UI.Components.Base.Component

  @type face_state :: :boot | :idle | :thinking | :working | :done | :error

  @type t :: %{
          id: String.t() | atom(),
          state: face_state(),
          frame: non_neg_integer(),
          ascii: boolean(),
          style: map(),
          theme: map()
        }

  # Branded (≡) faces, one frame list per state. Every entry is exactly four
  # display columns.
  @unicode %{
    boot: ["≡--≡", "≡··≡", "≡oo≡", "≡··≡"],
    idle: ["≡··≡", "≡··≡", "≡··≡", "≡--≡"],
    thinking: ["≡··≡", "≡''≡", "≡..≡"],
    working: ["≡oo≡", "≡OO≡"],
    done: ["≡^^≡"],
    error: ["≡xx≡"]
  }

  # ASCII-only fallback (gills `=`, ASCII eyes). Same four-column discipline.
  @ascii %{
    boot: ["=--=", "=..=", "=oo=", "=..="],
    idle: ["=..=", "=..=", "=..=", "=--="],
    thinking: ["=..=", "=''=", "=,,="],
    working: ["=oo=", "=OO="],
    done: ["=^^="],
    error: ["=xx="]
  }

  @states [:boot, :idle, :thinking, :working, :done, :error]

  @doc "The face states, in canonical order."
  @spec states() :: [face_state()]
  def states, do: @states

  @doc """
  The face glyph for `state` at `frame`, ASCII if `ascii?`.

  Pure: the single source of truth shared by every surface. `frame` wraps
  over the state's cycle length, so any non-negative integer is valid.
  """
  @spec glyph(face_state(), non_neg_integer(), boolean()) :: String.t()
  def glyph(state, frame, ascii? \\ false)
      when state in @states and is_integer(frame) and frame >= 0 do
    frames = Map.fetch!(if(ascii?, do: @ascii, else: @unicode), state)
    Enum.at(frames, rem(frame, length(frames)))
  end

  @doc "Foreground color for a state's face (nil = terminal default)."
  @spec color(face_state()) :: atom() | nil
  def color(:boot), do: :cyan
  def color(:idle), do: nil
  def color(:thinking), do: :cyan
  def color(:working), do: :cyan
  def color(:done), do: :green
  def color(:error), do: :red

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id: Ids.default_id(props, "axol-face"),
      state: Keyword.get(props, :state, :idle),
      frame: Keyword.get(props, :frame, 0),
      ascii: Keyword.get(props, :ascii, false),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    base_style = StyleHelper.merge_component_styles(state, context, :axol_face)

    %{
      type: :row,
      style: base_style,
      children: [
        Raxol.View.Components.text(
          id: "#{state.id}-face",
          content: glyph(state.state, state.frame, state.ascii),
          fg: color(state.state),
          style: face_text_style(state.state)
        )
      ]
    }
  end

  defp face_text_style(:idle), do: %{dim: true}
  defp face_text_style(:working), do: %{bold: true}
  defp face_text_style(:done), do: %{bold: true}
  defp face_text_style(:error), do: %{bold: true}
  defp face_text_style(_), do: %{}
end
