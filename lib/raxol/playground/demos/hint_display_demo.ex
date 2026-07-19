defmodule Raxol.Playground.Demos.HintDisplayDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.HintDisplay` — contextual help and
  tooltip rendering. The module is a pure config + string renderer (not a
  Base.Component): `init/1` builds config, `register_hint/4` stores text by
  component id, and `render/2` / `render_inline/3` return binaries that this
  demo splits into View `text/1` rows.

  Stories (top to bottom):

    * style showcase — `:tooltip` / `:inline` / `:minimal` for the same hint
    * type prefixes — info / warning / error / success / help under tooltip
    * max-width truncation (ellipsis)
    * `render_inline/3` positions (below / above / right) next to content
    * interactive: cycle style, type, and which registered hint is shown
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.HintDisplay

  @styles [:tooltip, :inline, :minimal]
  @types [:info, :warning, :error, :success, :help]
  @positions [:below, :above, :right]
  @hint_ids ["save-btn", "delete-btn", "search"]
  @max_width 28

  @impl true
  def init(_context) do
    config =
      HintDisplay.init(style: :tooltip, max_width: @max_width, position: :below)
      |> HintDisplay.register_hint("save-btn", "Persist the current buffer",
        type: :info
      )
      |> HintDisplay.register_hint(
        "delete-btn",
        "Permanently remove the selected item — cannot be undone",
        type: :warning,
        priority: 1
      )
      |> HintDisplay.register_hint("search", "Filter the list as you type",
        type: :help
      )

    %{
      config: config,
      style_index: 0,
      type_index: 0,
      position_index: 0,
      hint_index: 0
    }
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("s") ->
        {%{model | style_index: rem(model.style_index + 1, length(@styles))},
         []}

      key_match("t") ->
        {%{model | type_index: rem(model.type_index + 1, length(@types))}, []}

      key_match("p") ->
        {%{
           model
           | position_index: rem(model.position_index + 1, length(@positions))
         }, []}

      key_match("h") ->
        {%{model | hint_index: rem(model.hint_index + 1, length(@hint_ids))},
         []}

      key_match("c") ->
        {%{model | config: HintDisplay.clear_hints(model.config)}, []}

      key_match("r") ->
        # re-register the three demo hints after a clear
        config =
          model.config
          |> HintDisplay.register_hint(
            "save-btn",
            "Persist the current buffer",
            type: :info
          )
          |> HintDisplay.register_hint(
            "delete-btn",
            "Permanently remove the selected item — cannot be undone",
            type: :warning,
            priority: 1
          )
          |> HintDisplay.register_hint(
            "search",
            "Filter the list as you type",
            type: :help
          )

        {%{model | config: config}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    style = Enum.at(@styles, model.style_index)
    type = Enum.at(@types, model.type_index)
    position = Enum.at(@positions, model.position_index)
    hint_id = Enum.at(@hint_ids, model.hint_index)

    interactive_cfg = %{
      model.config
      | style: style,
        max_width: @max_width,
        position: position
    }

    sample_hint = %{text: "sample contextual tip", type: type, priority: 0}

    registered = HintDisplay.get_hint(model.config, hint_id)

    inline_cfg = %{model.config | style: :inline, position: position}

    inline_blob =
      HintDisplay.render_inline("[Save]", "save-btn", inline_cfg)

    column style: %{gap: 0} do
      [
        text("HintDisplay — Raxol.UI.Components.HintDisplay", style: [:bold]),
        text(" pure config + string render (not Base.Component)",
          style: [:dim]
        ),
        text(""),
        caption("style showcase (same text, three styles):"),
        section_lines(style_showcase()),
        text(""),
        caption("type prefixes under :tooltip:"),
        section_lines(type_showcase()),
        text(""),
        caption("max_width=#{@max_width} truncation:"),
        section_lines(truncation_showcase()),
        text(""),
        caption("render_inline position=#{position}:"),
        section_lines(lines_of(inline_blob)),
        text(""),
        caption(
          "interactive: style=#{style} type=#{type} hint=#{inspect(hint_id)}"
        ),
        section_lines(HintDisplay.render(sample_hint, interactive_cfg)),
        section_lines(registered_lines(registered, interactive_cfg)),
        text(""),
        text(
          " [s] style  [t] type  [p] position  [h] registered hint  [c] clear  [r] re-register",
          style: [:dim]
        )
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  # -- static showcases ----------------------------------------------------

  defp style_showcase do
    hint = %{text: "hover for help", type: :info, priority: 0}

    Enum.map_join(@styles, "\n", fn style ->
      cfg =
        HintDisplay.init(style: style, max_width: @max_width, position: :right)

      "#{style}: #{String.trim(HintDisplay.render(hint, cfg))}"
    end)
  end

  defp type_showcase do
    cfg =
      HintDisplay.init(style: :tooltip, max_width: @max_width, position: :right)

    Enum.map_join(@types, "\n\n", fn type ->
      hint = %{text: "#{type} message", type: type, priority: 0}
      String.trim(HintDisplay.render(hint, cfg))
    end)
  end

  defp truncation_showcase do
    long =
      "This is a deliberately long hint that should ellipsis once it exceeds max_width"

    cfg =
      HintDisplay.init(style: :inline, max_width: @max_width, position: :right)

    String.trim(
      HintDisplay.render(%{text: long, type: :info, priority: 0}, cfg)
    )
  end

  defp registered_lines(nil, _cfg), do: ["(no registered hint — press r)"]

  defp registered_lines(hint, cfg) do
    lines_of(HintDisplay.render(hint, cfg))
  end

  # -- render helpers (binary -> view rows) --------------------------------

  defp caption(str), do: text(str, style: [:dim])

  defp section_lines(blob) when is_binary(blob) do
    column style: %{gap: 0} do
      Enum.map(lines_of(blob), fn line -> text("  " <> line) end)
    end
  end

  defp section_lines(lines) when is_list(lines) do
    column style: %{gap: 0} do
      Enum.map(lines, fn line -> text("  " <> line) end)
    end
  end

  defp lines_of(blob) when is_binary(blob) do
    blob
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> case do
      [] -> [""]
      lines -> lines
    end
  end
end
