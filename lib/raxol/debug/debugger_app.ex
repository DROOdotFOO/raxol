defmodule Raxol.Debug.DebuggerApp do
  @moduledoc """
  Interactive debugger UI for time-travel debugging -- "React DevTools for the terminal."

  A TEA app wrapping the TimeTravel GenServer. Displays a timeline of snapshots,
  diffs between states, and a collapsible model inspector.

  ## Layout

      +===================================================================+
      | RAXOL DEBUGGER          Recording   Cursor: 42/156   +12.3s      |
      +===================================================================+
      | TIMELINE            | DIFF (Snapshot #42)                         |
      | > #42 :tick (2)     |   count  41 -> 42                          |
      |   #41 :tick (2)     | + items.new "hello"                        |
      |   #40 :key (1)      | - old_field "removed"                      |
      |   ...               |---------------------------------------------|
      |                     | MODEL INSPECTOR (#42.model_after)           |
      |                     |   count: 42                                 |
      |                     | v items: {3 keys}                           |
      |                     |     name: "todo"                            |
      +===================================================================+
      | [h/l] step  [j/k] scroll  [Tab] panel  [Space] pause  [q] quit  |
      +===================================================================+

  Launch with `mix raxol.debugger` or `Raxol.start_link(DebuggerApp, [])`.
  """

  use Raxol.Core.Runtime.Application

  alias Raxol.Debug.{DiffFormatter, Inspector, Snapshot, TimeTravel}

  @refresh_active 500

  @impl true
  def init(_context) do
    tt_ref = Application.get_env(:raxol, :debugger_tt_ref, TimeTravel)

    connected = tt_ref_alive?(tt_ref)
    entries = if connected, do: safe_list_entries(tt_ref), else: []
    count = length(entries)

    model = %{
      tt_ref: tt_ref,
      connected: connected,
      entries: entries,
      count: count,
      cursor_index: if(count > 0, do: List.last(entries).index, else: nil),
      current_snapshot: nil,
      panel: :timeline,
      timeline_offset: 0,
      diff_changes: [],
      diff_offset: 0,
      expanded_paths: MapSet.new(),
      inspector_offset: 0,
      inspector_lines: [],
      paused: false,
      jump_mode: false,
      jump_buffer: ""
    }

    load_current_snapshot(model)
  end

  @impl true
  def update(:refresh, model), do: {refresh(model), []}

  def update(message, model) do
    if model.jump_mode do
      handle_jump_mode(message, model)
    else
      handle_normal_mode(message, model)
    end
  end

  defp handle_jump_mode(message, model) do
    case message do
      key_match("c", ctrl: true) ->
        {model, [Directive.stop()]}

      key_match(:char, char: ch) when ch in ~w(0 1 2 3 4 5 6 7 8 9) ->
        {%{model | jump_buffer: model.jump_buffer <> ch}, []}

      key_match(:enter) ->
        {jump_to(model), []}

      key_match(:escape) ->
        {%{model | jump_mode: false, jump_buffer: ""}, []}

      _ ->
        {model, []}
    end
  end

  defp handle_normal_mode(message, model) do
    handle_quit_keys(message, model) ||
      handle_navigation_keys(message, model) ||
      handle_action_keys(message, model) ||
      handle_scroll(message, model)
  end

  defp handle_quit_keys(message, model) do
    case message do
      key_match("q") -> {model, [Directive.stop()]}
      key_match("c", ctrl: true) -> {model, [Directive.stop()]}
      _ -> nil
    end
  end

  defp handle_navigation_keys(message, model) do
    case message do
      key_match("h") -> step(model, :back)
      key_match("l") -> step(model, :forward)
      key_match(:left) -> step(model, :back)
      key_match(:right) -> step(model, :forward)
      _ -> nil
    end
  end

  defp handle_action_keys(message, model) do
    case message do
      key_match(:tab) ->
        {cycle_panel(model), []}

      key_match(" ") ->
        {toggle_pause(model), []}

      key_match("r") ->
        {restore(model), []}

      key_match("g") ->
        {%{model | jump_mode: true, jump_buffer: ""}, []}

      key_match(:enter) when model.panel == :inspector ->
        {toggle_inspector_node(model), []}

      _ ->
        nil
    end
  end

  defp handle_scroll(message, model) do
    case message do
      %Raxol.Core.Events.Event{type: :key, data: %{key: key}}
      when key in [:up, :down] ->
        delta = if key == :up, do: -1, else: 1
        {scroll_panel(model, delta), []}

      key_match(:char, char: ch) when ch in ["j", "k"] ->
        delta = if ch == "k", do: -1, else: 1
        {scroll_panel(model, delta), []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{gap: 0} do
      [
        header_bar(model),
        divider(),
        row style: %{gap: 0} do
          [
            timeline_panel(model),
            divider(char: "|"),
            column style: %{gap: 0} do
              [
                diff_panel(model),
                divider(),
                inspector_panel(model)
              ]
            end
          ]
        end,
        divider(),
        footer(model)
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(@refresh_active, :refresh)]
  end

  # -- View helpers --

  defp header_bar(model) do
    status = if model.paused, do: "Paused", else: "Recording"
    connection = if model.connected, do: "", else: " [DISCONNECTED]"

    cursor_str =
      if model.cursor_index,
        do: "Cursor: #{model.cursor_index}/#{model.count}",
        else: "Empty"

    jump_str = if model.jump_mode, do: "  JUMP: #{model.jump_buffer}_", else: ""

    row style: %{gap: 2} do
      [
        text("RAXOL DEBUGGER", style: [:bold]),
        text(status <> connection),
        text(cursor_str),
        text(jump_str)
      ]
    end
  end

  defp timeline_panel(model) do
    is_active = model.panel == :timeline
    title_style = if is_active, do: [:bold, :underline], else: [:bold]

    visible_entries =
      model.entries
      |> Enum.reverse()
      |> Enum.drop(model.timeline_offset)
      |> Enum.take(20)

    items =
      Enum.map(visible_entries, fn entry ->
        prefix = if entry.index == model.cursor_index, do: "> ", else: "  "
        style = if entry.index == model.cursor_index, do: [:bold], else: []
        text(prefix <> entry.summary, style: style)
      end)

    empty = if items == [], do: [text("  (no snapshots)")], else: []

    box style: %{width: 28, padding: 1} do
      column style: %{gap: 0} do
        [text("TIMELINE", style: title_style) | items ++ empty]
      end
    end
  end

  defp diff_panel(model) do
    is_active = model.panel == :diff
    title_style = if is_active, do: [:bold, :underline], else: [:bold]

    idx = model.cursor_index
    title = if idx, do: "DIFF (Snapshot ##{idx})", else: "DIFF"

    lines =
      model.diff_changes
      |> Enum.drop(model.diff_offset)
      |> Enum.take(10)
      |> Enum.map(fn change ->
        {prefix, detail} = DiffFormatter.render_line(change)
        style = diff_style(change.type)
        text(prefix <> detail, style: style)
      end)

    empty = if lines == [], do: [text("  (no changes)")], else: []

    box style: %{padding: 1} do
      column style: %{gap: 0} do
        [text(title, style: title_style) | lines ++ empty]
      end
    end
  end

  defp inspector_panel(model) do
    is_active = model.panel == :inspector
    title_style = if is_active, do: [:bold, :underline], else: [:bold]

    lines =
      model.inspector_lines
      |> Enum.drop(model.inspector_offset)
      |> Enum.take(12)
      |> Enum.map(fn line ->
        indent = String.duplicate("  ", line.depth)

        marker =
          cond do
            not line.expandable -> " "
            line.expanded -> "v"
            true -> ">"
          end

        text("#{indent}#{marker} #{line.key}: #{line.value_preview}")
      end)

    empty = if lines == [], do: [text("  (no model)")], else: []

    box style: %{padding: 1} do
      column style: %{gap: 0} do
        [text("MODEL INSPECTOR", style: title_style) | lines ++ empty]
      end
    end
  end

  defp footer(model) do
    panel_name = Atom.to_string(model.panel)

    row style: %{gap: 2} do
      [
        text("[#{panel_name}]", style: [:bold]),
        text(
          "[h/l] step  [j/k] scroll  [Tab] panel  [Space] pause  [r] restore  [g] jump  [q] quit",
          style: [:dim]
        )
      ]
    end
  end

  defp diff_style(:added), do: [:bold]
  defp diff_style(:removed), do: [:dim]
  defp diff_style(:changed), do: []

  # -- State helpers --

  defp refresh(model) do
    if model.connected do
      entries = safe_list_entries(model.tt_ref)
      count = length(entries)

      %{model | entries: entries, count: count}
      |> maybe_advance_cursor()
      |> load_current_snapshot()
    else
      connected = tt_ref_alive?(model.tt_ref)
      if connected, do: refresh(%{model | connected: true}), else: model
    end
  end

  defp maybe_advance_cursor(model) do
    if not model.paused and model.count > 0 do
      last = List.last(model.entries)
      %{model | cursor_index: last.index}
    else
      model
    end
  end

  defp load_current_snapshot(model) do
    case model.cursor_index do
      nil ->
        %{model | current_snapshot: nil, diff_changes: [], inspector_lines: []}

      idx ->
        case TimeTravel.jump_to(model.tt_ref, idx) do
          {:ok, snap} ->
            changes = DiffFormatter.format_snapshot_diff(snap)
            lines = Inspector.flatten(snap.model_after, model.expanded_paths)

            %{
              model
              | current_snapshot: snap,
                diff_changes: changes,
                inspector_lines: lines
            }

          {:error, _} ->
            model
        end
    end
  end

  defp step(model, direction) do
    result =
      case direction do
        :back -> TimeTravel.step_back(model.tt_ref)
        :forward -> TimeTravel.step_forward(model.tt_ref)
      end

    case result do
      {:ok, snap} ->
        changes = DiffFormatter.format_snapshot_diff(snap)
        lines = Inspector.flatten(snap.model_after, model.expanded_paths)

        {%{
           model
           | cursor_index: snap.index,
             current_snapshot: snap,
             diff_changes: changes,
             diff_offset: 0,
             inspector_lines: lines
         }, []}

      {:error, _} ->
        {model, []}
    end
  end

  defp scroll_panel(model, delta) do
    case model.panel do
      :timeline ->
        max_offset = max(0, model.count - 20)

        import Raxol.Core.Utils.Math, only: [clamp: 3]

        new_offset = clamp(model.timeline_offset + delta, 0, max_offset)

        %{model | timeline_offset: new_offset}

      :diff ->
        import Raxol.Core.Utils.Math, only: [clamp: 3]
        max_offset = max(0, length(model.diff_changes) - 10)
        new_offset = clamp(model.diff_offset + delta, 0, max_offset)
        %{model | diff_offset: new_offset}

      :inspector ->
        import Raxol.Core.Utils.Math, only: [clamp: 3]
        max_offset = max(0, length(model.inspector_lines) - 12)

        new_offset = clamp(model.inspector_offset + delta, 0, max_offset)

        %{model | inspector_offset: new_offset}
    end
  end

  defp cycle_panel(model) do
    next =
      case model.panel do
        :timeline -> :diff
        :diff -> :inspector
        :inspector -> :timeline
      end

    %{model | panel: next}
  end

  defp toggle_pause(model) do
    new_paused = not model.paused

    if model.connected do
      if new_paused,
        do: TimeTravel.pause(model.tt_ref),
        else: TimeTravel.resume(model.tt_ref)
    end

    %{model | paused: new_paused}
  end

  defp restore(model) do
    if model.connected and model.cursor_index != nil do
      case TimeTravel.restore(model.tt_ref) do
        :ok -> :ok
        {:error, _reason} -> :ok
      end
    end

    model
  end

  defp jump_to(model) do
    case Integer.parse(model.jump_buffer) do
      {idx, ""} ->
        case TimeTravel.jump_to(model.tt_ref, idx) do
          {:ok, snap} ->
            changes = DiffFormatter.format_snapshot_diff(snap)
            lines = Inspector.flatten(snap.model_after, model.expanded_paths)

            %{
              model
              | cursor_index: idx,
                current_snapshot: snap,
                diff_changes: changes,
                diff_offset: 0,
                inspector_lines: lines,
                jump_mode: false,
                jump_buffer: ""
            }

          {:error, _} ->
            %{model | jump_mode: false, jump_buffer: ""}
        end

      _ ->
        %{model | jump_mode: false, jump_buffer: ""}
    end
  end

  defp toggle_inspector_node(model) do
    line = Enum.at(model.inspector_lines, model.inspector_offset)

    if line && line.expandable do
      new_expanded = Inspector.toggle(model.expanded_paths, line.path)

      new_lines =
        case model.current_snapshot do
          %Snapshot{model_after: m} -> Inspector.flatten(m, new_expanded)
          _ -> model.inspector_lines
        end

      %{model | expanded_paths: new_expanded, inspector_lines: new_lines}
    else
      model
    end
  end

  defp tt_ref_alive?(ref) when is_pid(ref), do: Process.alive?(ref)
  defp tt_ref_alive?(ref) when is_atom(ref), do: Process.whereis(ref) != nil
  defp tt_ref_alive?(_), do: false

  defp safe_list_entries(ref) do
    TimeTravel.list_entries(ref)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
