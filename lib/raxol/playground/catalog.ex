defmodule Raxol.Playground.Catalog do
  @moduledoc """
  Single source of truth for Raxol's widget catalog.

  Provides metadata, demo modules, and code snippets for all playground-ready
  widgets. Used by the terminal playground, web playground, and SSH playground.
  """

  alias Raxol.Playground.Demos
  alias Raxol.Playground.Snippet

  @type component :: %{
          name: String.t(),
          module: module(),
          category: atom(),
          description: String.t(),
          complexity: :basic | :intermediate | :advanced,
          tags: [String.t()],
          code_snippet: String.t(),
          shows: String.t() | nil,
          featured: boolean()
        }

  # No `code_snippet` here on purpose. Every entry's snippet is EXTRACTED
  # from its demo module's `# snippet:start` / `# snippet:end` region at
  # compile time (see `Raxol.Playground.Snippet`), so the code beside a demo
  # is code the demo actually contains and runs, and a missing marker pair
  # is a compile error rather than a card quietly showing prose.
  @component_specs [
    %{
      name: "Button",
      module: Demos.ButtonDemo,
      category: :input,
      description: "Interactive button with click handling",
      complexity: :basic,
      tags: ["input", "interactive", "click"]
    },
    %{
      name: "TextInput",
      module: Demos.TextInputDemo,
      category: :input,
      description: "Single-line text input with placeholder",
      complexity: :basic,
      tags: ["input", "form", "text"]
    },
    %{
      name: "Table",
      featured: true,
      module: Demos.TableDemo,
      category: :display,
      description:
        "Stateful Table: fixed-width grid with border modes (:grid|:inner|:none), " <>
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
      ]
    },
    %{
      name: "Progress",
      module: Demos.ProgressDemo,
      category: :feedback,
      description: "Progress bar with value tracking",
      complexity: :basic,
      tags: ["feedback", "loading", "progress"]
    },
    %{
      name: "Modal",
      featured: true,
      module: Demos.ModalDemo,
      category: :overlay,
      description: "Modal dialog with title and content",
      complexity: :intermediate,
      tags: ["overlay", "dialog", "focus"]
    },
    %{
      name: "Menu",
      module: Demos.MenuDemo,
      category: :navigation,
      description: "Selectable menu with keyboard navigation",
      complexity: :intermediate,
      tags: ["navigation", "keyboard", "selection"]
    },
    # --- Input widgets ---
    %{
      name: "Checkbox",
      module: Demos.CheckboxDemo,
      category: :input,
      description: "Toggle checkboxes with keyboard navigation",
      complexity: :basic,
      tags: ["input", "form", "toggle"]
    },
    %{
      name: "TextArea",
      module: Demos.TextAreaDemo,
      category: :input,
      description: "Multi-line text editor with insert/normal modes",
      complexity: :intermediate,
      tags: ["input", "form", "text", "multiline"]
    },
    %{
      name: "SelectList",
      module: Demos.SelectListDemo,
      category: :input,
      description: "Dropdown select list with keyboard navigation",
      complexity: :intermediate,
      tags: ["input", "form", "dropdown", "select"]
    },
    %{
      name: "RadioGroup",
      module: Demos.RadioGroupDemo,
      category: :input,
      description: "Grouped radio buttons with tab switching",
      complexity: :intermediate,
      tags: ["input", "form", "radio", "group"]
    },
    %{
      name: "PasswordField",
      module: Demos.PasswordFieldDemo,
      category: :input,
      description: "Password input with visibility toggle and strength meter",
      complexity: :basic,
      tags: ["input", "form", "password", "security"]
    },
    %{
      name: "Scrubber",
      featured: true,
      module: Demos.ScrubberDemo,
      category: :input,
      description:
        "Transport control over an ordered position: track, playhead, marks, " <>
          "clock, play/pause and a speed ladder. One widget for asciicast " <>
          "recordings, time-travel snapshots, and recorded web frames",
      complexity: :intermediate,
      tags: [
        "input",
        "transport",
        "scrubber",
        "timeline",
        "seek",
        "replay",
        "slider"
      ]
    },
    # --- Display widgets ---
    %{
      name: "Text",
      module: Demos.TextDemo,
      category: :display,
      description:
        "Text rendering with style variations, ellipsis truncation, line clamping, and pretty wrapping",
      complexity: :basic,
      tags: ["display", "text", "style", "wrap", "truncate", "ellipsis"]
    },
    %{
      name: "Tree",
      module: Demos.TreeDemo,
      category: :display,
      description: "Expandable tree view with keyboard navigation",
      complexity: :intermediate,
      tags: ["display", "tree", "hierarchy", "navigation"]
    },
    %{
      name: "StatusBar",
      module: Demos.StatusBarDemo,
      category: :display,
      description: "Status bar with live-updating fields",
      complexity: :basic,
      tags: ["display", "status", "bar", "info"]
    },
    %{
      name: "CodeBlock",
      module: Demos.CodeBlockDemo,
      category: :display,
      description:
        "CodeBlock: structured syntax tokens via Raxol.UI.SyntaxHighlighter " <>
          "(same path as DiffViewer); theme :one_dark by default",
      complexity: :basic,
      tags: ["display", "code", "syntax", "makeup", "highlighter"]
    },
    %{
      name: "Markdown",
      featured: true,
      module: Demos.MarkdownDemo,
      category: :display,
      description:
        "Full Markdown surface (headings, emphasis, lists, quotes, links, " <>
          "GFM tables, HR). Fenced code via CodeBlock/SyntaxHighlighter, raw toggle",
      complexity: :intermediate,
      tags: ["display", "markdown", "text", "rendering", "code", "highlight"]
    },
    %{
      name: "Harness Diff Viewer",
      module: Demos.HarnessDiffDemo,
      category: :display,
      description:
        "Pre-apply file diff: line-based unified/split view with +/- markers and line numbers",
      complexity: :intermediate,
      tags: ["harness", "diff", "display", "review", "agent"]
    },
    %{
      name: "Harness Transcript",
      module: Demos.HarnessTranscriptDemo,
      category: :display,
      description:
        "Agent-harness transcript blocks: completed message, collapsible reasoning, error",
      complexity: :intermediate,
      tags: ["harness", "display", "transcript", "agent", "collapsible"]
    },
    # --- Navigation/Layout widgets ---
    %{
      name: "Tabs",
      module: Demos.TabsDemo,
      category: :navigation,
      description: "Tab bar with keyboard switching and content panels",
      complexity: :basic,
      tags: ["navigation", "tabs", "panels"]
    },
    %{
      name: "SplitPane",
      module: Demos.SplitPaneDemo,
      category: :layout,
      description:
        "Resizable split pane with direction toggle, proportionally sized via {:pct, n}",
      complexity: :intermediate,
      tags: ["layout", "split", "pane", "resize", "pct"]
    },
    %{
      name: "Container",
      module: Demos.ContainerDemo,
      category: :layout,
      description: "Scrollable container with viewport controls",
      complexity: :basic,
      tags: ["layout", "container", "scroll", "viewport"]
    },
    # --- Chart/Visualization widgets ---
    %{
      name: "BEAM Dashboard",
      module: Demos.BeamDashboardDemo,
      category: :visualization,
      description:
        "Live dashboard of the VM rendering it: schedulers, memory, events",
      complexity: :intermediate,
      tags: ["dashboard", "beam", "introspection", "streaming"]
    },
    %{
      name: "Sparkline",
      module: Demos.SparklineDemo,
      category: :visualization,
      description: "Compact sparkline for inline data trends",
      complexity: :basic,
      tags: ["chart", "sparkline", "inline", "streaming"]
    },
    %{
      name: "LineChart",
      featured: true,
      module: Demos.LineChartDemo,
      category: :visualization,
      description: "Streaming braille-resolution line chart",
      complexity: :intermediate,
      tags: ["chart", "line", "braille", "streaming"]
    },
    %{
      name: "BarChart",
      module: Demos.BarChartDemo,
      category: :visualization,
      description: "Block-character bar chart with orientation toggle",
      complexity: :basic,
      tags: ["chart", "bar", "vertical", "horizontal"]
    },
    %{
      name: "ScatterChart",
      module: Demos.ScatterChartDemo,
      category: :visualization,
      description: "Braille scatter plot with animated clusters",
      complexity: :intermediate,
      tags: ["chart", "scatter", "braille", "animation"]
    },
    %{
      name: "Heatmap",
      module: Demos.HeatmapDemo,
      category: :visualization,
      description: "2D heatmap with color scale cycling",
      complexity: :basic,
      tags: ["chart", "heatmap", "color", "grid"]
    },
    # --- Effects widgets ---
    %{
      name: "Cursor Trail",
      module: Demos.CursorTrailDemo,
      category: :effects,
      description: "Animated cursor trail with presets",
      complexity: :intermediate,
      tags: ["effects", "cursor", "trail", "animation"]
    },
    %{
      name: "Panel Highlights",
      module: Demos.PanelHighlightsDemo,
      category: :effects,
      description: "Panel focus highlighting with border styles",
      complexity: :basic,
      tags: ["effects", "panel", "focus", "border"]
    },
    %{
      name: "Easing Functions",
      module: Demos.EasingDemo,
      category: :effects,
      description: "Animated easing function showcase",
      complexity: :intermediate,
      tags: ["effects", "easing", "animation", "curve"]
    },
    %{
      name: "Focus Ring",
      module: Demos.FocusRingDemo,
      category: :effects,
      description: "Accessibility focus ring indicators",
      complexity: :basic,
      tags: ["effects", "focus", "ring", "accessibility"]
    },
    %{
      name: "OSC Ambient",
      module: Demos.OscAmbientDemo,
      category: :effects,
      description:
        "Host-terminal desktop notification, taskbar progress, and pointer shape",
      complexity: :intermediate,
      tags: ["effects", "osc", "notification", "progress", "pointer"]
    },
    # --- REPL & VFS ---
    %{
      name: "Virtual FS",
      module: Demos.VfsDemo,
      category: :navigation,
      description: "In-memory virtual file system with shell-like commands",
      complexity: :intermediate,
      tags: ["navigation", "filesystem", "shell", "commands", "interactive"]
    },
    %{
      name: "REPL",
      module: Demos.ReplDemo,
      category: :input,
      description: "Interactive Elixir REPL with sandboxed evaluation",
      complexity: :advanced,
      tags: ["input", "repl", "eval", "elixir", "interactive"]
    },
    # --- Theming/color ---
    %{
      name: "Salience Palette",
      module: Demos.SalienceDemo,
      category: :display,
      description:
        "H-K salience colour solver: lightness solved per tier against the detected ground",
      complexity: :intermediate,
      tags: ["display", "color", "theme", "oklch", "perceptual"]
    },
    # --- Layout internals ---
    %{
      name: "Flex Layout",
      module: Demos.FlexLayoutDemo,
      category: :layout,
      description:
        "flex_wrap, align_content, gap, and flex: 1 growth, with min-content flooring",
      complexity: :intermediate,
      tags: ["layout", "flex", "wrap", "align_content", "gap", "min-content"]
    },
    %{
      name: "Scroll Anchor",
      module: Demos.ScrollAnchorDemo,
      category: :layout,
      description:
        "Viewport overflow_anchor: follow-tail pinning that releases when you scroll up",
      complexity: :intermediate,
      tags: ["layout", "scroll", "viewport", "overflow", "anchor"]
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
      ]
    },
    %{
      name: "Harness Panels",
      module: Demos.HarnessPanelsDemo,
      category: :display,
      description:
        "Read-only harness projection panels: worktracks kanban, rules (hard vs soft), memory, residual",
      complexity: :intermediate,
      tags: ["harness", "display", "kanban", "rules", "memory", "projection"]
    },
    %{
      name: "Harness Approval",
      module: Demos.HarnessApprovalDemo,
      category: :overlay,
      description:
        "Agent-harness approval gate: blast-radius preview and keyboard-driven allow/deny scope choice",
      complexity: :intermediate,
      tags: ["harness", "approval", "overlay", "blast-radius"]
    },
    %{
      name: "Harness Tool Blocks",
      featured: true,
      module: Demos.HarnessToolBlocksDemo,
      category: :display,
      description:
        "Agent tool-call/tool-result blocks with a status glyph and an untrusted-output taint badge",
      complexity: :intermediate,
      tags: ["harness", "display", "agent", "tool", "taint", "provenance"]
    }
  ]

  # Editing a demo recompiles the catalog, so a moved marker region cannot
  # serve a stale snippet.
  for spec <- @component_specs do
    @external_resource Snippet.path_for(spec.module)
  end

  # `shows` is the snippet's leading component call ("Viewport.init"): the
  # card sub-line that answers "which module is this?" under a
  # plain-language name. Derived from the snippet, so it cannot outlive
  # what it names, and nil where it would only repeat the name.
  @components Enum.map(@component_specs, fn spec ->
                path = Snippet.path_for(spec.module)

                snippet =
                  case Snippet.extract(path) do
                    {:ok, snippet} ->
                      snippet

                    :no_markers ->
                      raise "#{path} has no snippet markers; every demo " <>
                              "brackets its illustrative region in " <>
                              "'# snippet:start' / '# snippet:end'"
                  end

                subject = Snippet.subject(snippet)

                shows =
                  if Snippet.redundant?(spec.name, subject),
                    do: nil,
                    else: subject

                spec
                |> Map.put(:code_snippet, snippet)
                |> Map.put(:shows, shows)
                # The gallery's small hand-picked opening row; everything
                # else is not "unfeatured", just filed under its category.
                |> Map.put_new(:featured, false)
              end)

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
