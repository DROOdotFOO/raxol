defmodule Raxol.Playground.Demos.ProgressDemo do
  @moduledoc """
  Playground demo: real progress components — never the dead View DSL
  `progress()` (LayoutEngine drops `type: :progress`).

  Primary path is `Raxol.UI.Components.Display.Progress` (full Component:
  init / update_props / render). Stories also exercise the string/stateful
  APIs under `Raxol.UI.Components.Progress` (Bar, Spinner, Indeterminate,
  Circular) that harness meters and activity indicators use.

  Stories (top to bottom):
  * Display.Progress interactive (label + % + animated edge) — keys/`a` tick
  * Display.Progress snapshots at 0 / half / full
  * Progress.Bar styles (solid, blocks, dots, ascii)
  * Spinner (stateful init/update + frame text)
  * Indeterminate (frame-driven wave/pulse/bounce/slide)
  * Circular (small/medium string indicators at current value)
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Playground.DemoHelpers

  alias Raxol.UI.Components.Display.Progress

  alias Raxol.UI.Components.Progress.{
    Bar,
    Circular,
    Indeterminate,
    Spinner
  }

  @bar_width 30
  @max_progress 100
  @manual_step 5
  @auto_step 2
  @auto_tick_ms 200
  @spinner_styles [:dots, :line, :pulse, :bounce, :wave]
  @indet_styles [:wave, :pulse, :bounce, :slide]

  @impl true
  def init(_context) do
    value = 50

    %{
      value: value,
      auto: false,
      frame: 0,
      spinner_style_idx: 0,
      indet_style_idx: 0,
      # Primary interactive Display.Progress (updated via update_props)
      main:
        progress!(%{
          id: "prog-main",
          progress: value / @max_progress,
          width: @bar_width,
          show_percentage: true,
          label: "Loading",
          animated: true
        }),
      # Static snapshot stories — fixed props, never mutated
      empty_story:
        progress!(%{
          id: "prog-empty",
          progress: 0.0,
          width: @bar_width,
          show_percentage: true,
          label: "Empty"
        }),
      half_story:
        progress!(%{
          id: "prog-half",
          progress: 0.5,
          width: @bar_width,
          show_percentage: true,
          label: "Half"
        }),
      full_story:
        progress!(%{
          id: "prog-full",
          progress: 1.0,
          width: @bar_width,
          show_percentage: true,
          label: "Full"
        }),
      # Stateful spinner (init + update(:tick)); frame text rendered below
      spinner:
        Spinner.init(%{
          style: :dots,
          text: "working",
          colors: [:cyan, :blue],
          speed: 0
        }),
      event_log: []
    }
  end

  defp progress!(props) do
    {:ok, state} = Progress.init(props)
    state
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("=") ->
        set_value(model, min(model.value + @manual_step, @max_progress), "key =")

      key_match("-") ->
        set_value(model, max(model.value - @manual_step, 0), "key -")

      key_match("a") ->
        auto? = not model.auto
        model = DemoHelpers.log_event(model, "auto=#{auto?}")
        {%{model | auto: auto?}, []}

      key_match("r") ->
        set_value(model, 0, "reset")

      key_match("s") ->
        idx =
          DemoHelpers.cycle_next(model.spinner_style_idx, length(@spinner_styles))

        style = Enum.at(@spinner_styles, idx)
        spinner = Spinner.update({:set_style, style}, model.spinner)
        model = DemoHelpers.log_event(model, "spinner style=#{style}")
        {%{model | spinner_style_idx: idx, spinner: spinner}, []}

      key_match("i") ->
        idx = DemoHelpers.cycle_next(model.indet_style_idx, length(@indet_styles))
        style = Enum.at(@indet_styles, idx)
        model = DemoHelpers.log_event(model, "indet style=#{style}")
        {%{model | indet_style_idx: idx}, []}

      :tick when model.auto ->
        new_val =
          if model.value >= @max_progress, do: 0, else: model.value + @auto_step

        model = advance_animations(model)

        summary =
          if rem(model.frame, 5) == 0, do: "tick value=#{new_val}", else: nil

        set_value(model, new_val, summary)

      :tick ->
        # Keep spinner/indet animating even when the bar is paused
        {advance_animations(model), []}

      _ ->
        {model, []}
    end
  end

  defp set_value(model, value, summary) do
    main =
      apply_progress_props(model.main, %{
        progress: value / @max_progress
      })

    model = %{model | value: value, main: main}

    model =
      if is_binary(summary) do
        DemoHelpers.log_event(model, "#{summary} -> progress=#{main.progress}")
      else
        model
      end

    {model, []}
  end

  defp apply_progress_props(state, props) do
    # Display.Progress.update/2 for :update_props returns {state, commands}
    {new_state, _cmds} = Progress.update({:update_props, props}, state)
    new_state
  end

  defp advance_animations(model) do
    # Force elapsed past Spinner.speed. Monotonic ms can be negative on some
    # platforms, so "last_update: 0" is NOT safely in the past — subtract
    # from the current clock instead.
    now = System.monotonic_time(:millisecond)

    spinner =
      model.spinner
      |> Map.put(:last_update, now - max(model.spinner.speed, 1) - 1)
      |> then(&Spinner.update(:tick, &1))

    # Drive Display.Progress's optional edge animation frame as well
    # (update(:tick, ...) returns {:noreply, state, commands})
    {:noreply, main, _cmds} = Progress.update(:tick, model.main)

    %{model | frame: model.frame + 1, spinner: spinner, main: main}
  end

  @impl true
  def view(model) do
    pct = model.value
    spinner_style = Enum.at(@spinner_styles, model.spinner_style_idx)
    indet_style = Enum.at(@indet_styles, model.indet_style_idx)
    auto_label = if model.auto, do: "ON", else: "OFF"

    column style: %{gap: 0} do
      [
        text(
          "Progress — Display.Progress + Progress.{Bar,Spinner,Indeterminate,Circular}",
          style: [:bold]
        ),
        text(
          " (no View DSL progress() — LayoutEngine drops type: :progress)",
          style: [:dim]
        ),
        text(""),
        text(" interactive Display.Progress (update_props path):", style: [:dim]),
        text(
          "  value=#{pct}/#{@max_progress}  auto=#{auto_label}  label=#{inspect(model.main.label)}",
          style: [:dim]
        )
      ] ++
        progress_story(model.main) ++
        [
          text(""),
          text(" snapshots (0 / half / full):", style: [:dim])
        ] ++
        progress_story(model.empty_story) ++
        progress_story(model.half_story) ++
        progress_story(model.full_story) ++
        [
          text(""),
          text(" Progress.Bar styles (string API @ value=#{pct}):", style: [:dim]),
          text("  solid  #{Bar.bar(pct, width: 20, style: :solid)}"),
          text("  blocks #{Bar.bar(pct, width: 20, style: :blocks)}"),
          text("  dots   #{Bar.bar(pct, width: 20, style: :dots)}"),
          text("  ascii  #{Bar.bar(pct, width: 20, style: :ascii)}"),
          text("  #{Bar.bar_with_label(pct, "download", width: 16, style: :blocks)}"),
          text(""),
          text(
            " Spinner (stateful init/update, style=#{spinner_style}):",
            style: [:dim]
          ),
          spinner_line(model.spinner),
          text(
            "  gallery: " <>
              Enum.map_join(@spinner_styles, "  ", fn style ->
                Spinner.spinner(nil, model.frame, type: style) <> " #{style}"
              end),
            style: [:dim]
          ),
          text(""),
          text(
            " Indeterminate (style=#{indet_style}, frame=#{model.frame}):",
            style: [:dim]
          ),
          text(
            "  #{Indeterminate.indeterminate(model.frame, style: indet_style, width: 24)}"
          ),
          text(
            "  " <>
              Enum.map_join(@indet_styles, "  ", fn style ->
                "#{style}#{Indeterminate.indeterminate(model.frame, style: style, width: 10)}"
              end),
            style: [:dim]
          ),
          text(""),
          text(" Circular (at value=#{pct}):", style: [:dim]),
          text(
            "  small  #{String.trim(Circular.circular(pct, size: :small, style: :blocks))}"
          ),
          text(
            "  medium #{String.trim(Circular.circular(pct, size: :medium, style: :ascii))}"
          ),
          text(""),
          text(
            " [=/-] value  [a] auto  [r] reset  [s] spinner style  [i] indet style",
            style: [:dim]
          ),
          text("")
        ] ++ DemoHelpers.event_log_lines(model)
    end
  end

  # Display.Progress.render/2 returns a list of absolute-positioned overlay
  # elements (box frame + fill text + optional label/%). Flow layout will not
  # overlay them, so we project the real render tree into one flow-friendly
  # line while still going through the Component's render path.
  defp progress_story(state) do
    elements = List.wrap(Progress.render(state, %{}))
    fill = extract_bar_fill(elements) || bar_fill_fallback(state)
    pct = round(state.progress * 100)
    label = state.label || "progress"
    [text("  #{label}: [#{fill}] #{pct}%")]
  end

  # Bar fill is only full/partial block glyphs + spaces (never digits/`%`/letters).
  defp extract_bar_fill(elements) do
    Enum.find_value(elements, fn
      %{type: :text, content: c} when is_binary(c) ->
        if bar_fill_content?(c), do: c, else: nil

      _ ->
        nil
    end)
  end

  defp bar_fill_content?(c) do
    byte_size(c) > 0 and String.match?(c, ~r/^[ █▏▎▍▌▋▊▉]*$/u)
  end

  defp bar_fill_fallback(state) do
    width = max(state.width - 2, 4)
    filled = floor(state.progress * width)
    String.duplicate("█", filled) <> String.duplicate(" ", max(width - filled, 0))
  end

  defp spinner_line(state) do
    frame = Enum.at(state.frames, state.frame_index) || "?"
    color = Enum.at(state.colors || [], state.color_index) || :cyan

    content =
      case {state.text, state.text_position} do
        {nil, _} -> frame
        {t, :left} -> "#{t} #{frame}"
        {t, _} -> "#{frame} #{t}"
      end

    text("  #{content}", fg: color)
  end

  @impl true
  def subscribe(_model) do
    # Always tick so spinner/indet animate; bar only advances when auto is on
    [subscribe_interval(@auto_tick_ms, :tick)]
  end
end
