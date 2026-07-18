defmodule Raxol.UI.Components.Harness.ShadowStream do
  @moduledoc """
  A **labeled, height-bounded, gradient-faded window over a live text
  stream** — where the *dominating primitive* (the label) shares the
  faintest row instead of wasting one on itself (V, 2026-07-18).

  This is not a "thinking" feature. It is a rendering pattern for any
  streaming process with a header you want to peek-bound: thinking,
  `searching…`, `compiling…`, a live log tail. The primitive is a
  parameter, so a translated UI or a different word costs nothing.

  ## The dominating primitive

  Whatever the state, the primitive is the through-line: **always rendered,
  always at `base` prominence** (the anchor). What changes around it is how
  much of the stream is shown.

  ## Three states (cycle on click)

    * `:fully_collapsed` — ONLY the primitive: `▸ thinking`.
    * `:peek` — the shadow window (the fancy render, below).
    * `:expanded` — `▾ thinking` + the full contents, bracketed `∵ … ∴`
      through `Raxol.UI.Components.Harness.Indication` (the primitives
      compose).

  ## The peek window (the magic)

  The last `height` stream lines, faded on an **age gradient** — newest at
  `base`, each older line stepping down (`age_prom/2`, slightly
  exponential). Two regimes:

    * **build-up** (fewer than `height` lines): the primitive gets its own
      top row at `base`; the lines fade below it by age.
    * **squeeze** (`height` lines or more): the primitive folds INTO the
      oldest line's row — primitive flush left at `base`, then a gap, then
      the oldest line's tail flush after it with a **per-character**
      horizontal fade (`floor → shadow_cap`), its overflow prefix consumed
      to `…`. The header never owns a row; the horizontal space it would
      waste carries the faintest stream line instead.

  Every colour comes from the same H-K salience solver the transcript uses
  (`Raxol.UI.Harness.Prominence.resolve/3`): lower prominence fades toward
  the background, `0.0` is invisible. Equal-colour runs are coalesced so a
  faded line is a handful of nodes, not one per character.

  ## Clicks

  The render root carries `:id` + `:on_click` (the `Bubbler` inline seam),
  so a click cycles the state. The caller owns the cycle; the component is
  pure.

  ## Tuning

  The fade curve lives in module attributes (`@floor`, `@shadow_cap`,
  `@k_line`, `@k_char`, `@gap`) — dial the feel without touching logic.
  `base`/`height`/`floor`/`width` are also per-instance props.
  """

  alias Raxol.UI.Harness.Prominence
  alias Raxol.UI.TextMeasure
  alias Raxol.UI.TextLayout
  alias Raxol.UI.Components.Harness.Indication

  # The transcript's neutral chrome colour (matches block.ex) — everything
  # fades from here toward the background as prominence drops.
  @chrome "#B4B4B4"

  @base 0.6
  @height 3
  # The faintest step (consumed-prefix / oldest edge) and the brightest the
  # shadow tail reaches (V: "fades in until 0.40").
  @floor 0.05
  @shadow_cap 0.4
  # Vertical (per-line, by age) and horizontal (per-char) fade exponents --
  # >1 slows the start (a gentle "fade in"), <1 rises fast.
  @k_line 0.65
  @k_char 1.5
  # Spaces between the primitive and the shadow tail sharing its row.
  @gap 3
  @ellipsis "…"

  @type render_state :: :fully_collapsed | :peek | :expanded

  @doc """
  Render the shadow stream as a view tree (a `:column` with `:id` +
  `:on_click` at the root). See the moduledoc for props.
  """
  @spec render(map()) :: map()
  def render(props) do
    p = normalize(props)

    %{
      type: :column,
      id: p.id,
      on_click: p.on_click,
      attrs: %{
        component_module: __MODULE__,
        kind: :shadow_stream,
        state: p.state,
        primitive: p.primitive
      },
      gap: 0,
      children: children(p)
    }
  end

  defp normalize(props) do
    width = Map.get(props, :width, 80)

    %{
      primitive: Map.get(props, :primitive, "thinking"),
      lines: props |> Map.get(:lines, []) |> to_lines(width),
      state: Map.get(props, :state, :peek),
      collapsed_icon: Map.get(props, :collapsed_icon, "▸"),
      expanded_icon: Map.get(props, :expanded_icon, "▾"),
      width: width,
      base: Map.get(props, :base, @base),
      height: max(Map.get(props, :height, @height), 1),
      floor: Map.get(props, :floor, @floor),
      id: Map.get(props, :id),
      on_click: Map.get(props, :on_click)
    }
  end

  # Reasoning arrives as prose that often has NO newlines (one long line);
  # windowing on `\n` alone would leave it a single line the peek then
  # truncates to `… ellipsis` instead of the 3-line shadow-cast. So wrap
  # each segment to `width` through the pretty (Knuth-Plass) wrapper — the
  # same balancer the transcript uses — then window the wrapped lines.
  defp to_lines(text, width) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.flat_map(&TextLayout.wrap(&1, max(width, 1), :normal, :pretty))
    |> Enum.reject(&(&1 == ""))
  end

  defp to_lines(lines, width) when is_list(lines) do
    lines
    |> Enum.flat_map(fn
      line when is_binary(line) ->
        TextLayout.wrap(line, max(width, 1), :normal, :pretty)

      other ->
        [other]
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp to_lines(_other, _width), do: []

  # ---- states -------------------------------------------------------------

  defp children(%{state: :fully_collapsed} = p),
    do: [line_node("#{p.collapsed_icon} #{p.primitive}", p.base)]

  defp children(%{state: :expanded} = p) do
    header = line_node("#{p.expanded_icon} #{p.primitive}", p.base)

    body = %{
      type: :column,
      gap: 0,
      children: Enum.map(p.lines, &line_node(&1, p.base))
    }

    [header, Indication.bracket(body, "∵", "∴", gutter_style: %{fg: fg(p.base)})]
  end

  defp children(%{state: :peek} = p) do
    case length(p.lines) do
      0 -> [line_node(p.primitive, p.base)]
      n when n < p.height -> buildup_rows(p, n)
      _full -> squeeze_rows(p)
    end
  end

  # Build-up: the primitive owns the top row; lines fade below it by age
  # (newest = base). No squeeze yet.
  defp buildup_rows(p, n) do
    body =
      p.lines
      |> Enum.with_index()
      |> Enum.map(fn {line, w} -> line_node(line, age_prom(n - 1 - w, p)) end)

    [line_node(p.primitive, p.base) | body]
  end

  # Squeeze: the last `height` lines. The oldest shares the primitive's row
  # as a per-char shadow; the rest are uniform, faded by age.
  defp squeeze_rows(p) do
    window = Enum.take(p.lines, -p.height)
    len = length(window)
    [oldest | rest] = window

    rest_rows =
      rest
      |> Enum.with_index(1)
      |> Enum.map(fn {line, w} -> line_node(line, age_prom(len - 1 - w, p)) end)

    [shadow_row(p, oldest) | rest_rows]
  end

  # The shared row: primitive (base, flush left), a gap, then the oldest
  # line's tail with a per-char horizontal fade. Overflow prefix -> `…`.
  defp shadow_row(p, oldest) do
    region = max(p.width - TextMeasure.display_width(p.primitive) - @gap, 1)

    spans =
      oldest
      |> fit_tail(region)
      |> fade_spans(region)

    %{
      type: :row,
      gap: 0,
      children:
        [
          %{type: :text, content: p.primitive, style: %{fg: fg(p.base)}},
          %{type: :text, content: String.duplicate(" ", @gap)}
        ] ++ spans
    }
  end

  # Keep the tail that fits `region`; consume any overflow prefix to `…`.
  defp fit_tail(line, region) do
    total = TextMeasure.display_width(line)

    if total <= region do
      line
    else
      {_dropped, kept} =
        TextMeasure.split_at_display_width(line, max(total - (region - 1), 0))

      @ellipsis <> kept
    end
  end

  # Per-char horizontal fade across the tail, coalescing equal-fg runs so a
  # faded line is a few nodes, not one per grapheme.
  defp fade_spans(tail, region) do
    tail
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.map(fn {g, col} -> {g, fg(char_prom(col, region))} end)
    |> Enum.chunk_by(fn {_g, fgc} -> fgc end)
    |> Enum.map(fn group ->
      %{
        type: :text,
        content: group |> Enum.map(&elem(&1, 0)) |> Enum.join(),
        style: %{fg: group |> hd() |> elem(1)}
      }
    end)
  end

  # ---- prominence curves --------------------------------------------------

  # Vertical, by AGE: age 0 (newest) = base; each older step fades toward
  # `floor` over `height-1` steps, slightly exponential. Age-based (not
  # index/count) so build-up and squeeze agree on every shared row.
  defp age_prom(0, p), do: p.base

  defp age_prom(age, p) do
    denom = max(p.height - 1, 1)
    t = max(1.0 - age / denom, 0.0)
    p.floor + (p.base - p.floor) * :math.pow(t, @k_line)
  end

  # Horizontal, per-char: col 0 (left / consumed prefix) = floor, rising to
  # `shadow_cap` at the region's right edge, slightly exponential. Anchored
  # to the region width, so a SHORT tail stays in the faint low columns.
  defp char_prom(_col, region) when region <= 1, do: @floor

  defp char_prom(col, region) do
    t = min(col / (region - 1), 1.0)
    min(@floor + (@shadow_cap - @floor) * :math.pow(t, @k_char), @shadow_cap)
  end

  defp fg(prominence), do: Prominence.resolve(@chrome, prominence, [])

  defp line_node(content, prominence),
    do: %{type: :text, content: content, style: %{fg: fg(prominence)}}
end
