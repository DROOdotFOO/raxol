defmodule Raxol.Playground.Catalog do
  @moduledoc """
  Single source of truth for Raxol's widget catalog.

  Provides metadata, demo modules, and code snippets for all playground-ready
  widgets. Used by the terminal playground, web playground, and SSH playground.
  """

  alias Raxol.Playground.Demos

  @type component :: %{
          name: String.t(),
          module: module(),
          category: atom(),
          description: String.t(),
          complexity: :basic | :intermediate | :advanced,
          tags: [String.t()],
          code_snippet: String.t()
        }

  @components [
    %{
      name: "Button",
      module: Demos.ButtonDemo,
      category: :input,
      description: "Interactive button with click handling",
      complexity: :basic,
      tags: ["input", "interactive", "click"],
      code_snippet: """
      button("Click Me", on_click: :clicked)
      button("Submit", on_click: :submit, style: [:bold])
      """
    },
    %{
      name: "TextInput",
      module: Demos.TextInputDemo,
      category: :input,
      description: "Single-line text input with placeholder",
      complexity: :basic,
      tags: ["input", "form", "text"],
      code_snippet: """
      text_input(value: model.name, placeholder: "Enter name...")
      """
    },
    %{
      name: "Table",
      module: Demos.TableDemo,
      category: :display,
      description:
        "Stateful Table — fixed-width grid with border modes (:grid|:inner|:none), " <>
          "sort, selection, pagination; keys route through Table.handle_event",
      complexity: :intermediate,
      tags: [
        "data",
        "display",
        "sorting",
        "rows",
        "pagination",
        "border",
        "controlled"
      ],
      code_snippet: """
      {:ok, table} =
        Table.init(%{
          id: :langs,
          columns: [
            %{id: :name, label: "Name", width: 12, align: :left},
            %{id: :language, label: "Language", width: 10, align: :left},
            %{id: :stars, label: "Stars", width: 6, align: :right}
          ],
          data: [%{name: "Raxol", language: "Elixir", stars: "500"}],
          options: %{
            border: :grid,            # :grid | :inner | :none
            header_separator: true,   # only for :none
            sortable: true,
            paginate: true,
            page_size: 4
          }
        })

      Table.render(table, %{})
      # :grid  -> full frame + rules
      # :inner -> column/row rules, no outer frame
      # :none  -> padded columns (+ optional header rule)
      """
    },
    %{
      name: "Progress",
      module: Demos.ProgressDemo,
      category: :feedback,
      description: "Progress bar with value tracking",
      complexity: :basic,
      tags: ["feedback", "loading", "progress"],
      code_snippet: """
      progress(value: 65, max: 100)
      """
    },
    %{
      name: "Modal",
      module: Demos.ModalDemo,
      category: :overlay,
      description: "Modal dialog with title and content",
      complexity: :intermediate,
      tags: ["overlay", "dialog", "focus"],
      code_snippet: """
      overlays =
        if model.show, do: [AbsoluteLayer.dialog_overlay(40, 17, dialog_box)], else: []

      AbsoluteLayer.absolute_layer(background_view(model), overlays)
      """
    },
    %{
      name: "Menu",
      module: Demos.MenuDemo,
      category: :navigation,
      description: "Selectable menu with keyboard navigation",
      complexity: :intermediate,
      tags: ["navigation", "keyboard", "selection"],
      code_snippet: """
      list(
        items: ["File", "Edit", "View", "Help"],
        selected: model.selected
      )
      """
    },
    # --- Input widgets ---
    %{
      name: "Checkbox",
      module: Demos.CheckboxDemo,
      category: :input,
      description: "Toggle checkboxes with keyboard navigation",
      complexity: :basic,
      tags: ["input", "form", "toggle"],
      code_snippet: ~s'checkbox("Enable Feature", checked: true)'
    },
    %{
      name: "TextArea",
      module: Demos.TextAreaDemo,
      category: :input,
      description: "Multi-line text editor with insert/normal modes",
      complexity: :intermediate,
      tags: ["input", "form", "text", "multiline"],
      code_snippet: ~s'textarea(value: model.text, rows: 5)'
    },
    %{
      name: "SelectList",
      module: Demos.SelectListDemo,
      category: :input,
      description: "Dropdown select list with keyboard navigation",
      complexity: :intermediate,
      tags: ["input", "form", "dropdown", "select"],
      code_snippet: ~s'select(options: ["Elixir", "Rust", "Go"], selected: 0)'
    },
    %{
      name: "RadioGroup",
      module: Demos.RadioGroupDemo,
      category: :input,
      description: "Grouped radio buttons with tab switching",
      complexity: :intermediate,
      tags: ["input", "form", "radio", "group"],
      code_snippet:
        ~s'radio_group(options: ["Light", "Dark", "Auto"], selected: 0)'
    },
    %{
      name: "PasswordField",
      module: Demos.PasswordFieldDemo,
      category: :input,
      description: "Password input with visibility toggle and strength meter",
      complexity: :basic,
      tags: ["input", "form", "password", "security"],
      code_snippet: ~s'text_input(value: model.password, type: :password)'
    },
    # --- Display widgets ---
    %{
      name: "Text",
      module: Demos.TextDemo,
      category: :display,
      description:
        "Text rendering with style variations, ellipsis truncation, line clamping, and pretty wrapping",
      complexity: :basic,
      tags: ["display", "text", "style", "wrap", "truncate", "ellipsis"],
      code_snippet: """
      text("Hello", style: [:bold, :italic])

      # CSS-style truncation/wrapping via Raxol.UI.Components.Display.Text:
      {:ok, state} = Text.init(content: line, width: 20, white_space: :nowrap, text_overflow: :ellipsis)
      Text.render(state, %{})
      """
    },
    %{
      name: "Tree",
      module: Demos.TreeDemo,
      category: :display,
      description: "Expandable tree view with keyboard navigation",
      complexity: :intermediate,
      tags: ["display", "tree", "hierarchy", "navigation"],
      code_snippet: ~s'list(items: tree_nodes, style: %{indent: 2})'
    },
    %{
      name: "StatusBar",
      module: Demos.StatusBarDemo,
      category: :display,
      description: "Status bar with live-updating fields",
      complexity: :basic,
      tags: ["display", "status", "bar", "info"],
      code_snippet:
        ~s'row do [text(mode), spacer(), text(file), text(line)] end'
    },
    %{
      name: "CodeBlock",
      module: Demos.CodeBlockDemo,
      category: :display,
      description:
        "CodeBlock — structured syntax tokens via Raxol.UI.SyntaxHighlighter " <>
          "(same path as DiffViewer); theme :one_dark by default",
      complexity: :basic,
      tags: ["display", "code", "syntax", "makeup", "highlighter"],
      code_snippet: """
      {:ok, block} =
        CodeBlock.init(%{
          content: ~s[def greet(name), do: "Hello, \#{name}!"],
          language: "elixir",
          theme: :one_dark   # shared with DiffViewer
        })

      # column of rows of text spans with hex fg from Makeup tokens
      CodeBlock.render(block, %{})
      """
    },
    %{
      name: "Markdown",
      module: Demos.MarkdownDemo,
      category: :display,
      description:
        "Full Markdown surface (headings, emphasis, lists, quotes, links, " <>
          "GFM tables, HR) — fenced code via CodeBlock/SyntaxHighlighter; raw toggle",
      complexity: :intermediate,
      tags: ["display", "markdown", "text", "rendering", "code", "highlight"],
      code_snippet: """
      {:ok, state} =
        MarkdownRenderer.init(%{
          markdown_text: \"\"\"
          # Title
          ```elixir
          def hello, do: :world
          ```
          \"\"\",
          width: 48,
          syntax_theme: :one_dark
        })

      MarkdownRenderer.render(state, %{})
      """
    },
    %{
      name: "Harness Diff Viewer",
      module: Demos.HarnessDiffDemo,
      category: :display,
      description:
        "Pre-apply file diff: line-based unified/split view with +/- markers and line numbers",
      complexity: :intermediate,
      tags: ["harness", "diff", "display", "review", "agent"],
      code_snippet: """
      {:ok, state} = DiffViewer.init(path: "lib/foo.ex", old: old_text, new: new_text)
      DiffViewer.render(state, %{})
      """
    },
    %{
      name: "Harness Transcript",
      module: Demos.HarnessTranscriptDemo,
      category: :display,
      description:
        "Agent-harness transcript blocks: completed message, collapsible reasoning, error",
      complexity: :intermediate,
      tags: ["harness", "display", "transcript", "agent", "collapsible"],
      code_snippet: """
      MessageBlock.render(message_state, %{})
      ReasoningBlock.render(reasoning_state, %{})  # collapsible, Enter/Space toggles
      ErrorBlock.render(error_state, %{})
      """
    },
    # --- Navigation/Layout widgets ---
    %{
      name: "Tabs",
      module: Demos.TabsDemo,
      category: :navigation,
      description: "Tab bar with keyboard switching and content panels",
      complexity: :basic,
      tags: ["navigation", "tabs", "panels"],
      code_snippet: ~s'tabs(labels: ["Tab 1", "Tab 2"], active: model.tab)'
    },
    %{
      name: "SplitPane",
      module: Demos.SplitPaneDemo,
      category: :layout,
      description:
        "Resizable split pane with direction toggle, proportionally sized via {:pct, n}",
      complexity: :intermediate,
      tags: ["layout", "split", "pane", "resize", "pct"],
      code_snippet: """
      row style: %{gap: 1, width: 60} do
        [
          box(style: %{width: {:pct, 30}, border: :single}, do: left_content),
          box(style: %{width: {:pct, 70}, border: :single}, do: right_content)
        ]
      end
      """
    },
    %{
      name: "Container",
      module: Demos.ContainerDemo,
      category: :layout,
      description: "Scrollable container with viewport controls",
      complexity: :basic,
      tags: ["layout", "container", "scroll", "viewport"],
      code_snippet: ~s'container(children: items, scroll_offset: model.offset)'
    },
    # --- Chart/Visualization widgets ---
    %{
      name: "BEAM Dashboard",
      module: Demos.BeamDashboardDemo,
      category: :visualization,
      description:
        "Live dashboard of the VM rendering it: schedulers, memory, events",
      complexity: :intermediate,
      tags: ["dashboard", "beam", "introspection", "streaming"],
      code_snippet:
        ~s':erlang.statistics(:scheduler_wall_time) # sampled each tick'
    },
    %{
      name: "Sparkline",
      module: Demos.SparklineDemo,
      category: :visualization,
      description: "Compact sparkline for inline data trends",
      complexity: :basic,
      tags: ["chart", "sparkline", "inline", "streaming"],
      code_snippet:
        ~s'sparkline(data: [10, 30, 50, 40, 60], width: 40, height: 5, color: :cyan)'
    },
    %{
      name: "LineChart",
      module: Demos.LineChartDemo,
      category: :visualization,
      description: "Streaming braille-resolution line chart",
      complexity: :intermediate,
      tags: ["chart", "line", "braille", "streaming"],
      code_snippet:
        ~s'line_chart(series: series, width: 60, height: 15, show_legend: true)'
    },
    %{
      name: "BarChart",
      module: Demos.BarChartDemo,
      category: :visualization,
      description: "Block-character bar chart with orientation toggle",
      complexity: :basic,
      tags: ["chart", "bar", "vertical", "horizontal"],
      code_snippet:
        ~s'bar_chart(series: series, width: 50, height: 12, orientation: :vertical)'
    },
    %{
      name: "ScatterChart",
      module: Demos.ScatterChartDemo,
      category: :visualization,
      description: "Braille scatter plot with animated clusters",
      complexity: :intermediate,
      tags: ["chart", "scatter", "braille", "animation"],
      code_snippet:
        ~s'scatter_chart(series: series, width: 60, height: 15, show_legend: true)'
    },
    %{
      name: "Heatmap",
      module: Demos.HeatmapDemo,
      category: :visualization,
      description: "2D heatmap with color scale cycling",
      complexity: :basic,
      tags: ["chart", "heatmap", "color", "grid"],
      code_snippet:
        ~s'heatmap(data: grid, width: 48, height: 16, color_scale: :warm)'
    },
    # --- Effects widgets ---
    %{
      name: "Cursor Trail",
      module: Demos.CursorTrailDemo,
      category: :effects,
      description: "Animated cursor trail with presets",
      complexity: :intermediate,
      tags: ["effects", "cursor", "trail", "animation"],
      code_snippet:
        ~s'trail = CursorTrail.rainbow() |> CursorTrail.update({x, y})'
    },
    %{
      name: "Panel Highlights",
      module: Demos.PanelHighlightsDemo,
      category: :effects,
      description: "Panel focus highlighting with border styles",
      complexity: :basic,
      tags: ["effects", "panel", "focus", "border"],
      code_snippet:
        ~s'box style: %{border: :rounded, fg: :cyan} do text(content) end'
    },
    %{
      name: "Easing Functions",
      module: Demos.EasingDemo,
      category: :effects,
      description: "Animated easing function showcase",
      complexity: :intermediate,
      tags: ["effects", "easing", "animation", "curve"],
      code_snippet: ~s'Easing.calculate_value(:ease_out_bounce, progress)'
    },
    %{
      name: "Focus Ring",
      module: Demos.FocusRingDemo,
      category: :effects,
      description: "Accessibility focus ring indicators",
      complexity: :basic,
      tags: ["effects", "focus", "ring", "accessibility"],
      code_snippet: ~s'FocusRing.render(content, FocusRing.init(style: :solid))'
    },
    %{
      name: "OSC Ambient",
      module: Demos.OscAmbientDemo,
      category: :effects,
      description:
        "Host-terminal desktop notification, taskbar progress, and pointer shape",
      complexity: :intermediate,
      tags: ["effects", "osc", "notification", "progress", "pointer"],
      code_snippet: ~s'IO.write(AdvancedFeatures.report_progress(:set, 42))'
    },
    # --- REPL & VFS ---
    %{
      name: "Virtual FS",
      module: Demos.VfsDemo,
      category: :navigation,
      description: "In-memory virtual file system with shell-like commands",
      complexity: :intermediate,
      tags: ["navigation", "filesystem", "shell", "commands", "interactive"],
      code_snippet: """
      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      {:ok, fs} = FileSystem.create_file(fs, "/docs/readme.txt", "Hello")
      {:ok, entries, fs} = FileSystem.ls(fs, "/docs")
      """
    },
    %{
      name: "REPL",
      module: Demos.ReplDemo,
      category: :input,
      description: "Interactive Elixir REPL with sandboxed evaluation",
      complexity: :advanced,
      tags: ["input", "repl", "eval", "elixir", "interactive"],
      code_snippet: """
      evaluator = Evaluator.new()
      {:ok, result, evaluator} = Evaluator.eval(evaluator, "1 + 2")
      result.value  #=> 3
      """
    },
    # --- Theming/color ---
    %{
      name: "Salience Palette",
      module: Demos.SalienceDemo,
      category: :display,
      description:
        "H-K salience colour solver: lightness solved per tier against the detected ground",
      complexity: :intermediate,
      tags: ["display", "color", "theme", "oklch", "perceptual"],
      code_snippet: """
      Salience.solve(:differentiate, 0.074, 242, ground: 0.1)
      SalienceTheme.build(ground: 0.92)
      """
    },
    # --- Layout internals ---
    %{
      name: "Flex Layout",
      module: Demos.FlexLayoutDemo,
      category: :layout,
      description:
        "flex_wrap, align_content, gap, and flex: 1 growth, with min-content flooring",
      complexity: :intermediate,
      tags: ["layout", "flex", "wrap", "align_content", "gap", "min-content"],
      code_snippet: """
      row style: %{flex_wrap: :wrap, align_content: :stretch, gap: 1} do
        [
          box(style: %{flex: 1, border: :single}, do: text("A")),
          box(style: %{border: :single}, do: text("Unbreakableword"))
        ]
      end
      """
    },
    %{
      name: "Scroll Anchor",
      module: Demos.ScrollAnchorDemo,
      category: :layout,
      description:
        "Viewport overflow_anchor: follow-tail pinning that releases when you scroll up",
      complexity: :intermediate,
      tags: ["layout", "scroll", "viewport", "overflow", "anchor"],
      code_snippet: """
      Viewport.init(children: lines, visible_height: 12, overflow_anchor: :auto)
      """
    },
    # --- Harness widgets ---
    %{
      name: "Harness Status",
      module: Demos.HarnessStatusDemo,
      category: :feedback,
      description:
        "Agent harness status bar, context/spend meters, activity indicator, advisory feed, and drift gauge",
      complexity: :intermediate,
      tags: [
        "harness",
        "status",
        "meter",
        "activity",
        "advisory",
        "drift",
        "toast"
      ],
      code_snippet: """
      {:ok, s} = ContextMeter.init(used: 13_000, total: 16_000)
      ContextMeter.render(s, %{})

      {:ok, s} = ActivityIndicator.init(state: :working, since_ms: 0, frame: 0)
      ActivityIndicator.render(s, %{})
      """
    },
    %{
      name: "Harness Panels",
      module: Demos.HarnessPanelsDemo,
      category: :display,
      description:
        "Read-only harness projection panels: worktracks kanban, rules (hard vs soft), memory, residual",
      complexity: :intermediate,
      tags: ["harness", "display", "kanban", "rules", "memory", "projection"],
      code_snippet: """
      {:ok, state} = WorktracksPanel.init(lanes: [
        %{name: "doing", items: [%{title: "Fold extract into board", status: "doing"}]}
      ])
      WorktracksPanel.render(state, %{})
      """
    },
    %{
      name: "Harness Approval",
      module: Demos.HarnessApprovalDemo,
      category: :overlay,
      description:
        "Agent-harness approval gate: blast-radius preview and keyboard-driven allow/deny scope choice",
      complexity: :intermediate,
      tags: ["harness", "approval", "overlay", "blast-radius"],
      code_snippet: """
      {:ok, approval} =
        ApprovalPrompt.init(
          id: "harness-approval",
          action: %{description: "Clear stale build cache", tool: "shell.exec"},
          blast_radius: %{deletes: ["/tmp/build/artifact.tar"], reversible: false}
        )

      AbsoluteLayer.dialog_overlay(
        approval.width,
        ApprovalPrompt.estimate_height(approval),
        ApprovalPrompt.render(approval, %{})
      )
      """
    },
    %{
      name: "Harness Tool Blocks",
      module: Demos.HarnessToolBlocksDemo,
      category: :display,
      description:
        "Agent tool-call/tool-result blocks with a status glyph and an untrusted-output taint badge",
      complexity: :intermediate,
      tags: ["harness", "display", "agent", "tool", "taint", "provenance"],
      code_snippet: """
      ToolCallBlock.init(name: "Bash", args: %{command: "ls"}, status: :running)
      ToolResultBlock.init(output: fetched_page, taint: true)  # composes TaintBadge
      """
    }
  ]

  @doc "Returns all playground components."
  @spec list_components() :: [component()]
  def list_components, do: @components

  @doc "Returns a component by name."
  @spec get_component(String.t()) :: component() | nil
  def get_component(name) do
    Enum.find(@components, &(&1.name == name))
  end

  @doc "Returns unique categories in display order."
  @spec list_categories() :: [atom()]
  def list_categories do
    @components
    |> Enum.map(& &1.category)
    |> Enum.uniq()
  end

  @doc "Filters components by keyword options."
  @spec filter(keyword()) :: [component()]
  def filter(opts \\ []) do
    @components
    |> filter_by_category(opts[:category])
    |> filter_by_complexity(opts[:complexity])
    |> filter_by_search(opts[:search])
  end

  defp filter_by_category(components, nil), do: components

  defp filter_by_category(components, category) do
    Enum.filter(components, &(&1.category == category))
  end

  defp filter_by_complexity(components, nil), do: components

  defp filter_by_complexity(components, complexity) do
    Enum.filter(components, &(&1.complexity == complexity))
  end

  defp filter_by_search(components, nil), do: components
  defp filter_by_search(components, ""), do: components

  defp filter_by_search(components, query) do
    q = String.downcase(query)

    Enum.filter(components, fn c ->
      String.contains?(String.downcase(c.name), q) or
        String.contains?(String.downcase(c.description), q) or
        Enum.any?(c.tags, &String.contains?(&1, q))
    end)
  end
end
