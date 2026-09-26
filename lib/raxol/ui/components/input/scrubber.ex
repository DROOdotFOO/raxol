defmodule Raxol.UI.Components.Input.Scrubber do
  @moduledoc """
  Transport control for anything with an ordered position: a track, a
  playhead, optional tick marks, a clock, and play/pause.

  Raxol has three unrelated timelines -- asciicast recordings
  (`Raxol.Recording.Session`, µs-stamped byte events), time-travel snapshots
  (`Raxol.Debug.TimeTravel`, absolute integer indices over a ring), and the
  web's prerecorded frame lists (uniform `interval_ms` ticks). Each had grown
  its own hand-assembled position readout and its own keymap. This is the one
  widget all three project onto.

  ## Features

  - Track with a sub-column playhead, filled and remaining runs distinguished
  - Tick marks at arbitrary positions (input events, changed snapshots, chapters)
  - Clock in `mm:ss / mm:ss` when a duration is known, `position/max` otherwise
  - Play/pause with a speed ladder matching `Raxol.Recording.Player`
  - Keyboard transport: step, jump to percent, jump to mark, ends
  - Pure renderers (`track/1`, `clock/1`, `line/1`) usable without a component
    tree, so an imperative caller writing to a TTY gets the same pixels

  ## Public API

  ### Props

  - `:id` - Widget identifier. Auto-minted from `Raxol.Core.ID` when absent.
  - `:min` - Lowest addressable position (integer, default `0`). Not always
    zero: a wrapped `TimeTravel` ring addresses `first..last`.
  - `:max` - Highest addressable position (integer, default `0`).
  - `:position` - Current position, clamped into `min..max`.
  - `:playing?` - Whether the transport is advancing (default `false`).
  - `:speed` - Playback multiplier (default `1.0`). Rendered only when not 1.0.
  - `:marks` - Positions to tick on the track (default `[]`). Out-of-range
    marks are dropped rather than clamped onto the ends, where they would
    read as a playhead at rest.
  - `:width` - Track width in columns (default `24`, floor `3`).
  - `:elapsed_ms` / `:duration_ms` - Wall-clock position and total. Supplied
    together by the caller rather than derived from `position`, because only
    a uniform-tick timeline has a linear index-to-time map; an asciicast does
    not.
  - `:label` - Optional leading label.
  - `:on_seek` - `(position -> message)`, run on every position change.
  - `:on_play` / `:on_pause` - `(-> message)`, run on the transport toggle.
  - `:on_speed` - `(speed -> message)`, run when the speed ladder moves.
  - `:disabled` - Inert: no key handling, no MCP tools.
  - `:aria_label`, `:tooltip` - Accessibility passthrough.

  ### Keys

  `space` play/pause; `left`/`h`/`,`/`<` back one; `right`/`l`/`.`/`>`
  forward one; `home`/`end` to the ends; `[`/`]` to the previous/next mark;
  `0`-`9` to 0%-90%; `+`/`=` and `-` up and down the speed ladder. Mined from
  `Raxol.Recording.Player`, so a player rebuilt on this widget keeps the
  bindings its docstring already advertises.

  ### Theming and Style Precedence

  Resolved by `Raxol.UI.StyleHelper.merge_component_styles/3` under the
  `:scrubber` key. `:disabled_fg` wins over `:focused_fg`, which wins over
  `:fg`; the filled run reads `:fg` and the remaining run `:track_fg`
  (falling back to `:dim_fg`, then `:fg`).

  ### Example

  A doctest, not a transcription: the previous hand-written "Rendered:" line
  disagreed with its own props in six ways (separator width, the mark at
  column 0, filled glyphs right of the playhead, two missing marks, two
  missing columns, and a `2x` label that `speed_label/1` suppresses at 1.0),
  and nothing executed it.

      iex> alias Raxol.UI.Components.Input.Scrubber
      iex> Scrubber.new(
      ...>   min: 0,
      ...>   max: 47,
      ...>   position: 12,
      ...>   duration_ms: 4_300,
      ...>   elapsed_ms: 1_100,
      ...>   marks: [0, 18, 33],
      ...>   playing?: true
      ...> )
      ...> |> Scrubber.line()
      ">   00:01 / 00:04  ┃━━━━━●──┃──────┃───────"
  """

  alias Raxol.Core.Utils.Math
  alias Raxol.UI.StyleHelper

  use Raxol.UI.Components.Base.Component
  @behaviour Raxol.MCP.ToolProvider
  @behaviour Raxol.Core.Accessibility.Provider

  @type t :: %{
          id: String.t(),
          label: String.t() | nil,
          min: integer(),
          max: integer(),
          position: integer(),
          playing?: boolean(),
          speed: float(),
          marks: [integer()],
          width: pos_integer(),
          elapsed_ms: non_neg_integer() | nil,
          duration_ms: non_neg_integer() | nil,
          on_seek: (integer() -> any()) | nil,
          on_play: (-> any()) | nil,
          on_pause: (-> any()) | nil,
          on_speed: (float() -> any()) | nil,
          disabled: boolean(),
          focused: boolean(),
          style: map(),
          theme: map(),
          aria_label: String.t() | nil,
          tooltip: String.t() | nil
        }

  # Box-drawing for the track so the filled and remaining runs differ in
  # weight rather than only in colour -- the widget has to read on a
  # monochrome SSH session and in a screenshot. The playhead is a geometric
  # circle because every mono stack has one; a media glyph would be a font
  # gamble, the same call `landing_components` made for its pause button.
  @filled "━"
  @remaining "─"
  @playhead "●"
  @mark "┃"

  # The ladder `Raxol.Recording.Player` already steps (player.ex @speed_steps).
  @speed_steps [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]

  @default_width 24
  @min_width 3

  # Both key spellings, as SelectList does: input backends disagree on
  # whether a named key arrives as a string or an atom.
  @key_mapping %{
    :space => :toggle_play,
    "Space" => :toggle_play,
    " " => :toggle_play,
    :left => :step_back,
    "Left" => :step_back,
    "h" => :step_back,
    "," => :step_back,
    "<" => :step_back,
    :right => :step_forward,
    "Right" => :step_forward,
    "l" => :step_forward,
    "." => :step_forward,
    ">" => :step_forward,
    :home => :to_start,
    "Home" => :to_start,
    :end => :to_end,
    "End" => :to_end,
    "[" => :prev_mark,
    "]" => :next_mark,
    "+" => :speed_up,
    "=" => :speed_up,
    "-" => :speed_down
  }

  @doc """
  Creates a scrubber state. See `init/1`.
  """
  @spec new(keyword() | map()) :: t()
  def new(props \\ []) do
    {:ok, state} = init(props)
    state
  end

  @impl Raxol.UI.Components.Base.Component
  @spec init(keyword() | map()) :: {:ok, t()}
  def init(props) do
    props = normalize_props(props)

    min = Map.get(props, :min, 0)
    max = max(min, Map.get(props, :max, 0))

    state = %{
      id: Map.get_lazy(props, :id, fn -> Raxol.Core.ID.next("scrubber") end),
      label: Map.get(props, :label),
      min: min,
      max: max,
      position: Math.clamp(Map.get(props, :position, min), min, max),
      playing?: Map.get(props, :playing?, false),
      speed: Map.get(props, :speed, 1.0),
      marks: sanitize_marks(Map.get(props, :marks, []), min, max),
      width: max(@min_width, Map.get(props, :width) || @default_width),
      elapsed_ms: Map.get(props, :elapsed_ms),
      duration_ms: Map.get(props, :duration_ms),
      on_seek: Map.get(props, :on_seek),
      on_play: Map.get(props, :on_play),
      on_pause: Map.get(props, :on_pause),
      on_speed: Map.get(props, :on_speed),
      disabled: Map.get(props, :disabled, false),
      focused: false,
      style: Map.get(props, :style, %{}),
      theme: Map.get(props, :theme, %{}),
      aria_label: Map.get(props, :aria_label),
      tooltip: Map.get(props, :tooltip)
    }

    {:ok, state}
  end

  @doc """
  Normalizes `props` into a view-tree node without minting an id.

  `init/1` mints one when `:id` is absent, which is right for a mounted
  component: it runs once, in the owning app's process, which is the premise
  `Raxol.Core.ID`'s per-process counter is documented against. A `view/1`
  helper runs on every frame, so minting there yielded `scrubber-1`,
  `scrubber-2`, ... on successive repaints -- churning the MCP tool handles
  (`TreeWalker` names them `"\#{widget_id}.seek"`), making
  `FocusHelper.focused?/2` unable to match a stable `focused_element`, and
  rewriting the `"\#{id}-track"` segment ids every frame.

  A declaration therefore carries whatever `:id` the caller gave, `nil`
  included. `TreeWalker.do_walk/4` requires a non-empty binary id, so an
  unnamed scrubber derives no tools rather than tools nobody can address --
  the same contract `progress/1` and the other declaration helpers have.
  """
  @spec declaration(keyword() | map()) :: map()
  def declaration(props) do
    {:ok, state} =
      props
      |> normalize_props()
      |> Map.put_new(:id, nil)
      |> init()

    to_node(state)
  end

  # -- Update ---------------------------------------------------------------
  #
  # A parent driving the transport (a playback timer, an MCP tool call routed
  # through the app's own update/2) speaks these three messages. Anything
  # else falls through to the prop merge the behaviour injects, so a re-render
  # with new `max`/`marks` re-clamps rather than stranding the playhead past
  # the end of a shortened timeline.

  @impl Raxol.UI.Components.Base.Component
  def update({:seek, position}, state), do: {seek(state, position), []}

  def update(:play, state), do: {%{state | playing?: true}, []}

  def update(:pause, state), do: {%{state | playing?: false}, []}

  def update(props, state) when is_map(props) or is_list(props) do
    {merged, commands} =
      Raxol.UI.Components.Base.Component.merge_props(
        normalize_props(props),
        state
      )

    {reclamp(merged), commands}
  end

  def update(_message, state), do: {state, []}

  # -- Events ---------------------------------------------------------------

  @impl Raxol.UI.Components.Base.Component
  def handle_event(%{__struct__: _} = event, state, context) do
    handle_event(Map.from_struct(event), state, context)
  end

  def handle_event(_event, %{disabled: true} = state, _context),
    do: {state, []}

  def handle_event(%{type: :key, data: data}, state, _context) do
    apply_action(action_for(data), state)
  end

  def handle_event(%{type: :focus}, state, _context),
    do: {%{state | focused: true}, []}

  def handle_event(%{type: :blur}, state, _context),
    do: {%{state | focused: false}, []}

  def handle_event(_event, state, _context), do: {state, []}

  # A digit is a jump to that decile, matching Player's 0..9 bindings; every
  # other key resolves through the shared table. `:char` events carry the
  # glyph in `:char`, named keys carry an atom (or its string spelling) in
  # `:key` -- read both rather than assuming a backend.
  defp action_for(data) do
    char = Map.get(data, :char)
    key = Map.get(data, :key)

    # The digit is read from BOTH fields, as the comment above promises and as
    # every other binding here already does. Reading it only from `:char` meant
    # a backend that delivers "5" in `:key` got `:none` from the table lookup
    # and the decile jump silently did not exist on that backend.
    case digit(char) || digit(key) do
      nil -> Map.get(@key_mapping, key) || Map.get(@key_mapping, char) || :none
      percent -> {:percent, percent}
    end
  end

  defp digit(<<code>>) when code in ?0..?9, do: (code - ?0) * 10
  defp digit(_other), do: nil

  defp apply_action(:none, state), do: {state, []}

  defp apply_action(:toggle_play, %{playing?: true} = state) do
    {%{state | playing?: false}, callback(state.on_pause)}
  end

  defp apply_action(:toggle_play, state) do
    {%{state | playing?: true}, callback(state.on_play)}
  end

  defp apply_action(:step_back, state), do: seek_with(state, state.position - 1)

  defp apply_action(:step_forward, state),
    do: seek_with(state, state.position + 1)

  defp apply_action(:to_start, state), do: seek_with(state, state.min)
  defp apply_action(:to_end, state), do: seek_with(state, state.max)

  defp apply_action({:percent, pct}, state) do
    seek_with(state, state.min + round(pct / 100 * span(state)))
  end

  defp apply_action(:prev_mark, state) do
    case state.marks
         |> Enum.filter(&(&1 < state.position))
         |> Enum.max(fn -> nil end) do
      nil -> {state, []}
      mark -> seek_with(state, mark)
    end
  end

  defp apply_action(:next_mark, state) do
    case state.marks
         |> Enum.filter(&(&1 > state.position))
         |> Enum.min(fn -> nil end) do
      nil -> {state, []}
      mark -> seek_with(state, mark)
    end
  end

  defp apply_action(:speed_up, state), do: step_speed_with(state, 1)
  defp apply_action(:speed_down, state), do: step_speed_with(state, -1)

  # `on_speed` for the same reason `on_seek` exists: the widget holds the
  # playback rate but does not own the timer that reads it, so a parent driving
  # playback had no way to learn that `+` was pressed and the ladder moved
  # nothing outside the widget's own render. Silent at the ends of the ladder,
  # as `seek_with/2` is at the ends of the track.
  defp step_speed_with(state, direction) do
    speed = step_speed(state.speed, direction)

    if speed == state.speed do
      {state, []}
    else
      {%{state | speed: speed}, callback(state.on_speed, speed)}
    end
  end

  # No callback and no command when the clamp lands on the position we were
  # already at: holding `left` at zero should not emit a seek per keypress.
  defp seek_with(state, target) do
    seeked = seek(state, target)

    if seeked.position == state.position do
      {state, []}
    else
      {seeked, callback(state.on_seek, seeked.position)}
    end
  end

  @doc """
  Moves the playhead, clamped into `min..max`.
  """
  @spec seek(t(), integer()) :: t()
  def seek(state, position) do
    %{state | position: Math.clamp(position, state.min, state.max)}
  end

  defp step_speed(speed, direction) do
    index =
      Enum.find_index(@speed_steps, &(&1 == speed)) ||
        Enum.find_index(@speed_steps, &(&1 == 1.0))

    Enum.at(
      @speed_steps,
      Math.clamp(index + direction, 0, length(@speed_steps) - 1)
    )
  end

  defp callback(fun) when is_function(fun, 0), do: [fun.()]
  defp callback(_fun), do: []

  defp callback(fun, arg) when is_function(fun, 1), do: [fun.(arg)]
  defp callback(_fun, _arg), do: []

  # -- Pure renderers -------------------------------------------------------

  @doc """
  Renders the track as a single string.

  Accepts the component state or a bare map/keyword of `:width`, `:min`,
  `:max`, `:position`, `:marks`. Column precedence is playhead, then mark,
  then the filled/remaining run, so a mark under the playhead never hides it.

      iex> Raxol.UI.Components.Input.Scrubber.track(width: 8, min: 0, max: 7, position: 3)
      "━━━●────"
  """
  @spec track(t() | keyword() | map()) :: String.t()
  def track(opts) do
    opts = normalize_props(opts)
    width = max(@min_width, Map.get(opts, :width) || @default_width)
    min = Map.get(opts, :min, 0)
    max_pos = max(min, Map.get(opts, :max, 0))
    position = Math.clamp(Map.get(opts, :position, min), min, max_pos)

    last = width - 1
    head = column_for(position, min, max_pos, last)
    columns = Map.get_lazy(opts, :mark_columns, fn -> mark_columns(opts) end)

    0..last
    |> Enum.map_join(fn col ->
      cond do
        col == head -> @playhead
        MapSet.member?(columns, col) -> @mark
        col < head -> @filled
        true -> @remaining
      end
    end)
  end

  @doc """
  The set of track columns carrying a mark, for a given width and range.

  `track/1` computes this itself unless `:mark_columns` is supplied, which is
  the point of exposing it: the work is `O(marks log marks)` and it depends on
  nothing that changes between frames. A caller repainting per event
  (`Raxol.Recording.Player` repaints its status bar on every output event)
  computes it once and passes it back, instead of re-sorting the whole mark
  list to draw at most `width` columns.
  """
  @spec mark_columns(t() | keyword() | map()) :: MapSet.t(non_neg_integer())
  def mark_columns(opts) do
    opts = normalize_props(opts)
    width = max(@min_width, Map.get(opts, :width) || @default_width)
    min = Map.get(opts, :min, 0)
    max_pos = max(min, Map.get(opts, :max, 0))
    last = width - 1

    opts
    |> Map.get(:marks, [])
    |> sanitize_marks(min, max_pos)
    |> MapSet.new(&column_for(&1, min, max_pos, last))
  end

  @doc """
  The columns `line/1` spends on everything except the track.

  A caller sizing the track to a terminal needs this and nothing else, so it
  must not be obtained by rendering a whole line and subtracting: that draws
  the track (and resolves every mark) purely to measure the parts beside it,
  which on a per-frame repaint is the dominant cost of the frame.
  """
  @spec chrome_width(t() | keyword() | map()) :: non_neg_integer()
  def chrome_width(opts) do
    opts = normalize_props(opts)

    parts =
      [transport(opts), clock(opts), speed_label(opts)]
      |> Enum.reject(&(&1 == ""))

    # The track is always rendered, so it is always one more joined part than
    # `parts` holds: that is `length(parts)` separators of two columns each.
    Enum.reduce(parts, 0, &(String.length(&1) + &2)) + 2 * length(parts)
  end

  @doc """
  Renders the position readout.

  `mm:ss / mm:ss` when `:duration_ms` is known, `position/max` otherwise --
  an index pair rather than a fabricated time, because only a uniform-tick
  timeline can turn an index into a timestamp.

      iex> Raxol.UI.Components.Input.Scrubber.clock(position: 12, min: 0, max: 47)
      "12/47"

      iex> Raxol.UI.Components.Input.Scrubber.clock(elapsed_ms: 63_000, duration_ms: 125_000)
      "01:03 / 02:05"
  """
  @spec clock(t() | keyword() | map()) :: String.t()
  def clock(opts) do
    opts = normalize_props(opts)

    case Map.get(opts, :duration_ms) do
      nil ->
        "#{Map.get(opts, :position, 0)}/#{Map.get(opts, :max, 0)}"

      duration ->
        "#{mmss(Map.get(opts, :elapsed_ms) || 0)} / #{mmss(duration)}"
    end
  end

  @doc """
  Renders the whole transport as one line: state glyph, clock, track, speed.

  This is the form an imperative caller writes straight to a TTY (see
  `Raxol.Recording.Player`), and it is what `render/2` composes from.
  """
  @spec line(t() | keyword() | map()) :: String.t()
  def line(opts) do
    opts = normalize_props(opts)

    [transport(opts), clock(opts), track(opts), speed_label(opts)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("  ")
  end

  @doc """
  The transport state glyph: `>` playing, `||` paused.

  State, not the action a button would take. Padded to two columns so the
  line does not shift when playback toggles.
  """
  @spec transport(t() | keyword() | map()) :: String.t()
  def transport(opts) do
    if normalize_props(opts) |> Map.get(:playing?, false), do: "> ", else: "||"
  end

  # `== 1.0` and not `1.0 ->`: pattern matching is exact, so integer `1` -- which
  # `step_speed/2` accepts, because it compares with `==` -- rendered "1x".
  defp speed_label(opts) do
    speed = Map.get(opts, :speed, 1.0)

    if speed == 1.0, do: "", else: "#{trim_float(speed)}x"
  end

  defp trim_float(speed) do
    if speed == trunc(speed), do: "#{trunc(speed)}", else: "#{speed}"
  end

  defp mmss(ms) do
    total = div(max(ms, 0), 1000)

    "#{pad(div(total, 60))}:#{pad(rem(total, 60))}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # The playhead sits on a column, not between columns: a seek has to be
  # reversible by eye, and a half-column playhead reads as two positions.
  defp column_for(_position, min, max_pos, _last) when max_pos <= min, do: 0

  defp column_for(position, min, max_pos, last) do
    round((position - min) / (max_pos - min) * last)
  end

  # -- Render ---------------------------------------------------------------

  @impl Raxol.UI.Components.Base.Component
  @spec render(t(), map()) :: map()
  def render(state, context) do
    focused = Raxol.UI.FocusHelper.focused?(state.id, context) or state.focused
    state = %{state | focused: focused}

    base_style = StyleHelper.merge_component_styles(state, context, :scrubber)
    {fg, bg} = colors(state, base_style)

    %{
      type: :row,
      style: %{gap: 1, fg: fg, bg: bg},
      children: segments(state, base_style, fg, bg)
    }
    |> Map.merge(extra_attrs(state))
  end

  # One text element per non-empty part, each with its own id so the browser
  # bridge and the accessibility projection can address the track separately
  # from the clock. The track reads `:track_fg` because the remaining run
  # wants to recede from the filled one on a colour terminal, while still
  # differing by weight where there is no colour.
  defp segments(state, base_style, fg, bg) do
    track_fg = Map.get(base_style, :track_fg, Map.get(base_style, :dim_fg, fg))
    text_style = text_attrs(base_style, bg)

    [
      {"label", state.label, fg},
      {"transport", transport(state), fg},
      {"clock", clock(state), fg},
      {"track", track(state), track_fg},
      {"speed", speed_label(state), fg}
    ]
    |> Enum.reject(fn {_part, content, _fg} ->
      is_nil(content) or content == ""
    end)
    |> Enum.map(fn {part, content, part_fg} ->
      Raxol.View.Components.text(
        id: "#{state.id}-#{part}",
        content: content,
        style: Map.put(text_style, :fg, part_fg)
      )
    end)
  end

  @doc """
  Renders the state as a declaration node carrying `type: :scrubber`.

  `render/2` alone is not discoverable: it lays out as a `:row`, and both
  `Raxol.MCP.TreeWalker` and `Raxol.Core.Accessibility.Projection` dispatch
  on the declaration type. This stamps the discovery alias and copies the
  transport fields onto the node, because `mcp_tools/1` and `a11y_node/1`
  read the node rather than component state.

  Emit this from a TEA `view/1` when the scrubber should be drivable by an
  agent or announced by a screen reader; `render/2` is enough for a purely
  visual bar.
  """
  @spec to_node(t(), map()) :: map()
  def to_node(state, context \\ %{}) do
    state
    |> render(context)
    |> Map.merge(%{
      type: :scrubber,
      id: state.id,
      min: state.min,
      max: state.max,
      position: state.position,
      playing?: state.playing?,
      speed: state.speed,
      marks: state.marks,
      label: state.label,
      disabled: state.disabled,
      focused: state.focused
    })
  end

  defp text_attrs(base_style, bg) do
    base_style
    |> StyleHelper.text_attributes()
    |> Map.put(:bg, bg)
  end

  defp colors(%{disabled: true}, base_style) do
    {Map.get(base_style, :disabled_fg, Map.get(base_style, :fg, :gray)),
     Map.get(base_style, :disabled_bg, Map.get(base_style, :bg, :default))}
  end

  defp colors(%{focused: true}, base_style) do
    {Map.get(base_style, :focused_fg, Map.get(base_style, :fg, :default)),
     Map.get(base_style, :focused_bg, Map.get(base_style, :bg, :default))}
  end

  defp colors(_state, base_style) do
    {Map.get(base_style, :fg, :default), Map.get(base_style, :bg, :default)}
  end

  defp extra_attrs(state) do
    %{aria_label: state.aria_label, tooltip: state.tooltip}
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  # -- Shared helpers -------------------------------------------------------

  defp normalize_props(props) when is_list(props), do: Map.new(props)
  defp normalize_props(props) when is_map(props), do: props

  defp span(%{min: min, max: max_pos}), do: max_pos - min

  # Out-of-range marks are dropped, not clamped: a clamped mark stacks on an
  # end column where it is indistinguishable from a parked playhead.
  defp sanitize_marks(marks, min, max_pos) when is_list(marks) do
    marks
    |> Enum.filter(&(is_integer(&1) and &1 >= min and &1 <= max_pos))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp sanitize_marks(_marks, _min, _max), do: []

  defp reclamp(state) do
    min = state.min
    max_pos = max(min, state.max)

    %{
      state
      | max: max_pos,
        position: Math.clamp(state.position, min, max_pos),
        marks: sanitize_marks(state.marks, min, max_pos),
        width: max(@min_width, state.width || @default_width)
    }
  end

  # -- ToolProvider callbacks ----------------------------------------------
  #
  # `mcp_tools/1` receives the view-tree node, not the component state, so
  # every read is bracket access with an `:attrs` fallback.

  @impl Raxol.MCP.ToolProvider
  def mcp_tools(%{attrs: %{disabled: true}}), do: []
  def mcp_tools(%{disabled: true}), do: []

  def mcp_tools(node) do
    name = tool_label(node)
    {min, max_pos} = tool_range(node)

    [
      %{
        name: "seek",
        description:
          "Move the '#{name}' playhead to a position (#{min}..#{max_pos})",
        inputSchema: %{
          type: "object",
          properties: %{
            position: %{
              type: "integer",
              description: "Target position (#{min}..#{max_pos})"
            }
          },
          required: ["position"]
        }
      },
      %{
        name: "play",
        description: "Start '#{name}' playback",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "pause",
        description: "Pause '#{name}' playback",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "get_position",
        description: "Read the '#{name}' position, range, and play state",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  # `mcp_tools/1` refusing to ADVERTISE a disabled scrubber is not enough to
  # stop a call: `TreeWalker.build_tool_def/5` closes over the node at walk
  # time, so an agent holding a tool def registered before the widget was
  # disabled would still move an inert transport. Refuse execution too, the way
  # `Button.handle_tool_call/3` already does. `get_position` stays allowed --
  # reading a disabled widget is what the a11y projection does anyway.
  @impl Raxol.MCP.ToolProvider
  def handle_tool_call(action, args, context)
      when action in ["seek", "play", "pause"] do
    node = context.widget_state

    if node_get(node, :disabled) == true do
      {:error, "Scrubber '#{tool_label(node)}' is disabled"}
    else
      do_tool_call(action, args, context)
    end
  end

  def handle_tool_call("get_position", _args, context) do
    node = context.widget_state
    {min, max_pos} = tool_range(node)

    {:ok,
     %{
       position: node_get(node, :position) || min,
       min: min,
       max: max_pos,
       playing: node_get(node, :playing?) == true
     }}
  end

  def handle_tool_call(action, _args, _ctx),
    do: {:error, "Unknown action: #{action}"}

  defp do_tool_call("seek", %{"position" => position}, context)
       when is_integer(position) do
    {min, max_pos} = tool_range(context.widget_state)

    if position < min or position > max_pos do
      {:error, "Position #{position} out of range (#{min}..#{max_pos})"}
    else
      {:ok, "Sought to #{position}",
       [{:scrubber_seek, context.widget_id, position}]}
    end
  end

  defp do_tool_call("seek", _args, _context),
    do: {:error, "seek requires an integer 'position'"}

  defp do_tool_call("play", _args, context) do
    {:ok, "Playing", [{:scrubber_play, context.widget_id}]}
  end

  defp do_tool_call("pause", _args, context) do
    {:ok, "Paused", [{:scrubber_pause, context.widget_id}]}
  end

  defp tool_label(node) do
    node_get(node, :aria_label) || node_get(node, :label) || "scrubber"
  end

  defp tool_range(node) do
    min = node_get(node, :min) || 0
    {min, max(min, node_get(node, :max) || 0)}
  end

  defp node_get(node, key) do
    node[key] || get_in(node, [:attrs, key])
  end

  # -- Accessibility -------------------------------------------------------

  @impl Raxol.Core.Accessibility.Provider
  def a11y_node(node) do
    {min, max_pos} = tool_range(node)

    %{
      role: :slider,
      label: tool_label(node),
      value: node_get(node, :position) || min,
      state: %{
        min: min,
        max: max_pos,
        playing?: node_get(node, :playing?) == true,
        disabled?: node_get(node, :disabled) == true,
        focused?: node_get(node, :focused) == true
      }
    }
  end
end
