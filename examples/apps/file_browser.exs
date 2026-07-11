# File Browser
#
# A file browser demonstrating Raxol's Tree widget, keyboard navigation,
# and real filesystem interaction. Browse directories, preview file contents,
# and see file metadata -- all in the terminal.
#
# Palette: Synthwave '84 Soft (mapped to ANSI)
#   cyan    -> directory names, active panel border
#   magenta -> status bar, key hints
#   yellow  -> file sizes, modified dates
#   green   -> selected item highlight
#
# Controls:
#   Up/Down    navigate tree
#   Right      expand directory
#   Left       collapse directory / go to parent
#   Enter      preview file contents
#   Tab        switch between tree and preview panels
#   q / Ctrl+C quit
#
# Usage:
#   mix run examples/apps/file_browser.exs
#   mix run examples/apps/file_browser.exs -- /some/path

defmodule FileBrowser do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @max_preview_lines 40
  @max_preview_bytes 8192

  # -- TEA Callbacks --

  @impl true
  def init(_context) do
    root = start_dir()

    %{
      cwd: root,
      tree_nodes: build_tree(root, 1),
      expanded: MapSet.new(),
      cursor: nil,
      panel: :tree,
      preview: nil,
      preview_name: nil,
      meta: nil,
      status: root,
      error: nil
    }
  end

  @impl true
  def update(message, model) do
    case message do
      # -- Keyboard --
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :tab}} ->
        next_panel = if model.panel == :tree, do: :preview, else: :tree
        {%{model | panel: next_panel}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :down}}
      when model.panel == :tree ->
        move_cursor(model, :down)

      %Raxol.Core.Events.Event{type: :key, data: %{key: :up}}
      when model.panel == :tree ->
        move_cursor(model, :up)

      %Raxol.Core.Events.Event{type: :key, data: %{key: :right}}
      when model.panel == :tree ->
        expand_node(model)

      %Raxol.Core.Events.Event{type: :key, data: %{key: :left}}
      when model.panel == :tree ->
        collapse_node(model)

      %Raxol.Core.Events.Event{type: :key, data: %{key: :enter}}
      when model.panel == :tree ->
        activate_node(model)

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{padding: 0} do
      [
        # Title bar
        row style: %{height: 1} do
          [
            text(" FILE BROWSER ", fg: :cyan, style: [:bold]),
            text("  Tab:switch  arrows:navigate  Enter:preview  q:quit",
              fg: :magenta
            )
          ]
        end,
        # Main content
        row style: %{flex: 1} do
          [
            # Tree panel
            box style: %{
                  border: if(model.panel == :tree, do: :double, else: :single),
                  # only {:pct, n} is %; "40%" becomes :auto
                  width: {:pct, 40},
                  padding: 0,
                  # clip so a deeply expanded tree can't bleed past the panel
                  overflow: :hidden
                } do
              column do
                tree_lines(model)
              end
            end,
            # Preview panel
            box style: %{
                  border:
                    if(model.panel == :preview, do: :double, else: :single),
                  flex: 1,
                  padding: 0,
                  # clip so a long file preview can't bleed past the panel
                  overflow: :hidden
                } do
              column do
                preview_content(model)
              end
            end
          ]
        end,
        # Status bar
        row style: %{height: 1} do
          [
            text(" #{model.status} ",
              fg: :black,
              bg: :magenta,
              style: [:bold]
            ),
            if model.error do
              text("  #{model.error}", fg: :red)
            else
              text("")
            end
          ]
        end
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  # -- Tree rendering --

  defp tree_lines(model) do
    visible = visible_nodes(model.tree_nodes, model.expanded, 0)

    if visible == [] do
      [text("  (empty directory)", fg: :yellow)]
    else
      Enum.map(visible, fn {node, depth} ->
        indent = String.duplicate("  ", depth)
        icon = node_icon(node, model.expanded)
        is_selected = node.id == model.cursor

        fg_color = if node.is_dir, do: :cyan, else: :white

        if is_selected do
          text("#{indent}#{icon} #{node.label}",
            fg: :black,
            bg: :green,
            style: [:bold]
          )
        else
          text("#{indent}#{icon} #{node.label}", fg: fg_color)
        end
      end)
    end
  end

  defp node_icon(%{is_dir: true, children: []}, _expanded), do: "📁"

  defp node_icon(%{is_dir: true, id: id}, expanded) do
    if MapSet.member?(expanded, id), do: "📂", else: "📁"
  end

  defp node_icon(%{label: label}, _expanded) do
    cond do
      String.ends_with?(label, ".ex") ->
        "💧"

      String.ends_with?(label, ".exs") ->
        "💧"

      String.ends_with?(label, ".md") ->
        "📄"

      String.ends_with?(label, ".json") ->
        "📋"

      String.ends_with?(label, ".toml") ->
        "⚙"

      String.ends_with?(label, ".yml") or String.ends_with?(label, ".yaml") ->
        "⚙"

      true ->
        "  "
    end
  end

  # -- Preview rendering --

  defp preview_content(%{preview: nil, meta: nil}) do
    [
      text(""),
      text("  Press Enter on a file to preview", fg: :magenta),
      text("  Press Right on a directory to expand", fg: :magenta)
    ]
  end

  defp preview_content(%{preview: lines, preview_name: name, meta: meta})
       when is_list(lines) do
    header = [
      text(" #{name}", fg: :cyan, style: [:bold]),
      text(
        " #{format_size(meta.size)}  #{format_time(meta.mtime)}",
        fg: :yellow
      ),
      text(String.duplicate("─", 60), fg: :magenta)
    ]

    content =
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {line, num} ->
        num_str = num |> Integer.to_string() |> String.pad_leading(4)
        text(" #{num_str} │ #{line}", fg: :white)
      end)

    header ++ content
  end

  defp preview_content(%{preview: msg}) when is_binary(msg) do
    [text("  #{msg}", fg: :yellow)]
  end

  # -- Navigation --

  defp move_cursor(model, direction) do
    visible = visible_nodes(model.tree_nodes, model.expanded, 0)
    ids = Enum.map(visible, fn {node, _} -> node.id end)

    new_cursor =
      case {direction, Enum.find_index(ids, &(&1 == model.cursor))} do
        {_, nil} -> List.first(ids)
        {:down, idx} -> Enum.at(ids, min(idx + 1, length(ids) - 1))
        {:up, idx} -> Enum.at(ids, max(idx - 1, 0))
      end

    node = find_node(model.tree_nodes, new_cursor)
    status = if node, do: node.path, else: model.status

    {%{model | cursor: new_cursor, status: status}, []}
  end

  defp expand_node(model) do
    node = find_node(model.tree_nodes, model.cursor)

    cond do
      node == nil ->
        {model, []}

      node.is_dir and not MapSet.member?(model.expanded, model.cursor) ->
        children = build_tree(node.path, 1)
        tree_nodes = replace_children(model.tree_nodes, model.cursor, children)
        expanded = MapSet.put(model.expanded, model.cursor)
        {%{model | tree_nodes: tree_nodes, expanded: expanded}, []}

      true ->
        {model, []}
    end
  end

  defp collapse_node(model) do
    cond do
      MapSet.member?(model.expanded, model.cursor) ->
        expanded = MapSet.delete(model.expanded, model.cursor)
        {%{model | expanded: expanded}, []}

      true ->
        # Move to parent
        visible = visible_nodes(model.tree_nodes, model.expanded, 0)

        parent_id =
          find_parent_id(model.tree_nodes, model.cursor)

        if parent_id do
          node = find_node(model.tree_nodes, parent_id)
          status = if node, do: node.path, else: model.status
          {%{model | cursor: parent_id, status: status}, []}
        else
          {model, []}
        end
    end
  end

  defp activate_node(model) do
    node = find_node(model.tree_nodes, model.cursor)

    cond do
      node == nil ->
        {model, []}

      node.is_dir ->
        expand_node(model)

      true ->
        case read_preview(node.path) do
          {:ok, lines, meta} ->
            {%{
               model
               | preview: lines,
                 preview_name: node.label,
                 meta: meta,
                 error: nil
             }, []}

          {:error, reason} ->
            {%{
               model
               | preview: "Cannot preview: #{reason}",
                 preview_name: node.label,
                 meta: nil,
                 error: nil
             }, []}
        end
    end
  end

  # -- Filesystem --

  defp start_dir do
    case System.argv() do
      ["--" | [path | _]] -> Path.expand(path)
      _ -> File.cwd!()
    end
  end

  defp build_tree(dir, _depth) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort_by(fn name ->
          path = Path.join(dir, name)
          {not File.dir?(path), String.downcase(name)}
        end)
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.map(fn name ->
          path = Path.join(dir, name)
          is_dir = File.dir?(path)

          %{
            id: String.to_atom(path),
            label: name,
            path: path,
            is_dir: is_dir,
            children:
              if(is_dir,
                do: [
                  %{
                    id: :"#{path}/__placeholder",
                    label: "...",
                    path: path,
                    is_dir: false,
                    children: []
                  }
                ],
                else: []
              )
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp read_preview(path) do
    with {:ok, stat} <- File.stat(path),
         true <- stat.size <= @max_preview_bytes,
         {:ok, content} <- File.read(path),
         true <- String.valid?(content) do
      lines =
        content
        |> String.split("\n")
        |> Enum.take(@max_preview_lines)

      meta = %{size: stat.size, mtime: stat.mtime}
      {:ok, lines, meta}
    else
      false -> {:error, "file too large or binary"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # -- Tree helpers --

  defp visible_nodes([], _expanded, _depth), do: []

  defp visible_nodes([node | rest], expanded, depth) do
    entry = [{node, depth}]

    child_entries =
      if node.is_dir and MapSet.member?(expanded, node.id) do
        real_children =
          Enum.reject(node.children, fn c ->
            String.ends_with?(to_string(c.id), "/__placeholder")
          end)

        visible_nodes(real_children, expanded, depth + 1)
      else
        []
      end

    entry ++ child_entries ++ visible_nodes(rest, expanded, depth)
  end

  defp find_node([], _id), do: nil
  defp find_node([%{id: id} = node | _], id), do: node

  defp find_node([%{children: children} | rest], id) do
    case find_node(children, id) do
      nil -> find_node(rest, id)
      found -> found
    end
  end

  defp find_node([_ | rest], id), do: find_node(rest, id)

  defp find_parent_id(nodes, id), do: do_find_parent(nodes, id, nil)

  defp do_find_parent([], _id, _parent), do: nil
  defp do_find_parent([%{id: id} | _], id, parent), do: parent

  defp do_find_parent([%{children: children} = node | rest], id, parent) do
    case do_find_parent(children, id, node.id) do
      nil -> do_find_parent(rest, id, parent)
      found -> found
    end
  end

  defp do_find_parent([_ | rest], id, parent),
    do: do_find_parent(rest, id, parent)

  defp replace_children(nodes, target_id, new_children) do
    Enum.map(nodes, fn node ->
      cond do
        node.id == target_id ->
          %{node | children: new_children}

        node.children != [] ->
          %{
            node
            | children: replace_children(node.children, target_id, new_children)
          }

        true ->
          node
      end
    end)
  end

  # -- Formatting --

  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"

  defp format_size(bytes) when bytes < 1024 * 1024,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  defp format_size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp format_time({{y, m, d}, {h, min, _s}}) do
    "#{y}-#{pad(m)}-#{pad(d)} #{pad(h)}:#{pad(min)}"
  end

  defp format_time(_), do: ""

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"
end

Raxol.Core.Runtime.Log.info("FileBrowser: Starting...")
{:ok, pid} = Raxol.start_link(FileBrowser, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
