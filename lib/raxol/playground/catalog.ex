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
      # View DSL button (wired via Bubbler on_click)
      button("Primary [1]", id: "primary_btn", on_click: :primary)
      button("Submit", on_click: :submit, style: [:bold])

      # or the Component form:
      {:ok, btn} = Button.init(%{id: "ok", label: "OK", on_click: :ok})
      Button.render(btn, %{})
      """
    },
    %{
      name: "TextInput",
      module: Demos.TextInputDemo,
      category: :input,
      description:
        "TextInput (Event-based single-line) — placeholder, max_length, " <>
          "cursor nav; keys route through TextInput.handle_event. " <>
          "No disabled (use TextField); PasswordField wraps TextField.",
      complexity: :basic,
      tags: ["input", "form", "text", "controlled"],
      code_snippet: """
      {:ok, field} =
        TextInput.init(%{
          id: "name",
          placeholder: "Type here...",
          focused: true,
          max_length: 32
        })

      # playground keys use %{key: :char, char: ch}; TextInput wants key=char string
      {field, _cmds} =
        TextInput.handle_event(Event.key("a"), field, %{})
      TextInput.render(field, %{})
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
      description:
        "Display.Progress (init/update_props/render) + Progress.Bar/Spinner/" <>
          "Indeterminate/Circular stories — 0/half/full, auto-tick, never View DSL progress()",
      complexity: :intermediate,
      tags: [
        "feedback",
        "loading",
        "progress",
        "spinner",
        "indeterminate",
        "circular",
        "controlled"
      ],
      code_snippet: """
      {:ok, bar} =
        Display.Progress.init(%{
          progress: 0.65,
          width: 30,
          show_percentage: true,
          label: "Loading",
          animated: true
        })

      {bar, []} = Display.Progress.update({:update_props, %{progress: 0.8}}, bar)
      Display.Progress.render(bar, %{})

      # String APIs used by harness meters / activity indicators:
      Progress.Bar.bar(65, width: 20, style: :blocks)
      Progress.Spinner.spinner("working", frame, type: :dots)
      Progress.Indeterminate.indeterminate(frame, style: :wave, width: 24)
      Progress.Circular.circular(65, size: :small)
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
      surface =
        Modal.Rendering.dialog_surface(
          40,
          17,
          %{border: :double, bg: {30, 30, 45}},
          [dialog_content]
        )

      overlays =
        if model.show, do: [AbsoluteLayer.dialog_overlay(40, 17, surface)], else: []

      AbsoluteLayer.absolute_layer(background_view(model), overlays)
      """
    },
    %{
      name: "Menu",
      module: Demos.MenuDemo,
      category: :navigation,
      description:
        "Nested menu (Menu component) — submenu chain, disabled skip, shortcuts; " <>
          "keys route through Menu.handle_event",
      complexity: :intermediate,
      tags: ["navigation", "keyboard", "selection", "controlled"],
      code_snippet: """
      {:ok, menu} =
        Menu.init(
          id: "main-menu",
          focused: true,
          items: [
            %{id: :file, label: "File", disabled: false, shortcut: nil,
              children: [
                %{id: :new, label: "New", disabled: false, shortcut: "Ctrl+N", children: []}
              ]},
            %{id: :edit, label: "Edit", disabled: false, shortcut: nil, children: []}
          ]
        )

      {menu, _cmds} =
        Menu.handle_event(%Event{type: :key, data: %{key: :down}}, menu, %{})
      Menu.render(menu, %{})
      """
    },
    # --- Input widgets ---
    %{
      name: "Checkbox",
      module: Demos.CheckboxDemo,
      category: :input,
      description:
        "Checkbox component — space/click toggle, disabled + required stories; " <>
          "demo owns j/k focus across a list of mounted checkboxes",
      complexity: :basic,
      tags: ["input", "form", "toggle", "controlled"],
      code_snippet: """
      {:ok, cb} =
        Checkbox.init(
          id: "feature",
          label: "Enable Feature",
          checked: true
        )

      {cb, _cmds} =
        Checkbox.handle_event(%Event{type: :key, data: %{key: :space}}, cb, %{})
      Checkbox.render(cb, %{})  # "[x] Enable Feature"
      """
    },
    %{
      name: "TextArea",
      module: Demos.TextAreaDemo,
      category: :input,
      description:
        "TextArea (thin MultiLineInput wrapper) — multi-line edit, wrap, " <>
          "scroll, placeholder; keys route through TextArea.handle_event " <>
          "(no vim modes)",
      complexity: :intermediate,
      tags: ["input", "form", "text", "multiline", "controlled"],
      code_snippet: """
      # TextArea is a thin wrapper around MultiLineInput
      {:ok, area} =
        TextArea.init(%{
          id: "notes",
          value: "Hello, world!\\nEdit me with arrows",
          width: 40,
          height: 5,
          focused: true,
          placeholder: "Type multi-line notes..."
        })

      {area, _cmds} =
        TextArea.handle_event(
          %Event{type: :key, data: %{key: :char, char: "x"}},
          area,
          %{}
        )
      TextArea.render(area, %{})
      """
    },
    %{
      name: "SelectList",
      module: Demos.SelectListDemo,
      category: :input,
      description:
        "SelectList component — always-open list with keyboard nav, multi-select, " <>
          "and search toggle; keys route through SelectList.handle_event",
      complexity: :intermediate,
      tags: ["input", "form", "select", "list", "controlled"],
      code_snippet: """
      {:ok, list} =
        SelectList.init(%{
          id: "lang",
          options: [
            {"Elixir", :elixir},
            {"Rust", :rust},
            {"Go", :go}
          ],
          has_focus: true,
          enable_search: true,
          max_height: 8
        })

      {list, _} =
        SelectList.handle_event(%{type: :key, data: %{key: :down}}, list, %{})
      SelectList.render(list, %{})
      """
    },
    %{
      name: "RadioGroup",
      module: Demos.RadioGroupDemo,
      category: :input,
      description:
        "Hand-rolled radio groups (no RadioGroup component yet) — demo model " <>
          "drives (o)/( ) marks with j/k selection and h/l group switching",
      complexity: :intermediate,
      tags: ["input", "form", "radio", "group", "hand-rolled"],
      code_snippet: """
      # No Raxol.UI.Components.* RadioGroup yet — hand-roll from model state:
      group = %{name: "Theme", options: ["Light", "Dark", "Auto"], selected: 0}

      options =
        Enum.with_index(group.options, fn opt, i ->
          mark = if i == group.selected, do: "(o)", else: "( )"
          text("  \#{mark} \#{opt}")
        end)

      column style: %{gap: 0} do
        [text(group.name, style: [:bold]) | options]
      end
      """
    },
    %{
      name: "PasswordField",
      module: Demos.PasswordFieldDemo,
      category: :input,
      description:
        "Password field (TextField with secret: true) — • masking, placeholder, " <>
          "cell-aware scroll, disabled state; keys route through PasswordField.handle_event",
      complexity: :basic,
      tags: ["input", "form", "password", "security", "controlled"],
      code_snippet: """
      {:ok, field} =
        PasswordField.init(%{
          id: "pw",
          placeholder: "hunter2",
          focused: true,
          width: 24
        })

      # keys route through the real component (TextField shape: {:keypress, key, mods})
      {field, _cmds} = PasswordField.handle_event({:keypress, "a", []}, field, %{})
      PasswordField.render(field, %{})  # one • per grapheme
      """
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
      name: "HintDisplay",
      module: Demos.HintDisplayDemo,
      category: :feedback,
      description:
        "Contextual hints and tooltips (pure config + string render — styles, types, inline positions)",
      complexity: :basic,
      tags: ["feedback", "hint", "tooltip", "help", "display"],
      code_snippet: """
      config =
        HintDisplay.init(style: :tooltip, max_width: 40, position: :below)
        |> HintDisplay.register_hint("save-btn", "Persist the buffer", type: :info)

      hint = HintDisplay.get_hint(config, "save-btn")
      HintDisplay.render(hint, config)
      # or: HintDisplay.render_inline("[Save]", "save-btn", config)
      """
    },
    %{
      name: "Tree",
      module: Demos.TreeDemo,
      category: :display,
      description:
        "Display.Tree — expand/collapse hierarchy; keys route through Tree.handle_event",
      complexity: :intermediate,
      tags: ["display", "tree", "hierarchy", "navigation", "controlled"],
      code_snippet: """
      {:ok, tree} =
        Tree.init(
          id: "fs",
          focused: true,
          indent_size: 2,
          nodes: [
            %{
              id: :src,
              label: "src",
              children: [
                %{id: :main, label: "main.ex", children: [], data: nil}
              ],
              data: nil
            }
          ]
        )

      {tree, _cmds} =
        Tree.handle_event(%Event{type: :key, data: %{key: :right}}, tree, %{})
      Tree.render(tree, %{})
      """
    },
    %{
      name: "StatusBar",
      module: Demos.StatusBarDemo,
      category: :display,
      description:
        "Display.StatusBar — non-interactive key/label items with live-updating labels",
      complexity: :basic,
      tags: ["display", "status", "bar", "info"],
      code_snippet: """
      {:ok, bar} =
        StatusBar.init(
          id: "status",
          separator: " │ ",
          items: [
            %{key: "Mode", label: "NORMAL"},
            %{key: "File", label: "demo.ex"},
            %{key: "Pos", label: "1:1"},
            %{key: "Up", label: "0s"}
          ]
        )

      StatusBar.render(bar, %{})
      """
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
      category: :harness_chat_widgets,
      description:
        "Pre-apply file diff (Pierre engine): unified/split body, word-diff emphasis, " <>
          "hunk folding, Enter/Space fold to the compact ± path · +N -M line",
      complexity: :intermediate,
      tags: ["harness", "diff", "display", "review", "agent", "fold"],
      code_snippet: """
      {:ok, state} = DiffViewer.init(path: "lib/foo.ex", old: old_text, new: new_text)
      DiffViewer.render(state, %{})          # full Pierre body
      DiffViewer.handle_event(enter, state, %{})  # -> folded ± path · +N -M
      """
    },
    %{
      name: "Harness Transcript",
      module: Demos.HarnessTranscriptDemo,
      category: :display,
      description:
        "Agent-harness transcript message block: a completed assistant message, bare prose",
      complexity: :intermediate,
      tags: ["harness", "display", "transcript", "agent"],
      code_snippet: """
      {:ok, s} = MessageBlock.init(id: "msg", role: :assistant, content: text)
      MessageBlock.render(s, %{})
      """
    },
    %{
      name: "Harness Assembled (TEA)",
      module: Demos.HarnessAssembledDemo,
      category: :harness,
      description:
        "The fully assembled TEA harness (U4): HarnessApp replaying a golden fixture — " <>
          "windowed transcript blocks, the fit-law footer with a live composer, parked cursor",
      complexity: :advanced,
      tags: [
        "harness",
        "tea",
        "transcript",
        "footer",
        "cursor",
        "assembled",
        "agent"
      ],
      code_snippet: """
      Model.build(events: session, pump: nil) |> Model.reveal_all()   # HarnessApp model
      View.render(model)                                              # windowed transcript + footer + :cursor
      Model.handle_key(model, event)                                  # folds / jumps / overlay picker
      """
    },
    %{
      name: "Harness Indication",
      module: Demos.HarnessIndicationDemo,
      category: :harness,
      description:
        "The left-edge indication primitive: content at column 2, gutter " <>
          "strategies (speaker sigil, ∵…∴ bracket, vertical rule) at column 0",
      complexity: :intermediate,
      tags: [
        "harness",
        "layout",
        "indication",
        "gutter",
        "contour",
        "primitive"
      ],
      code_snippet: """
      Indication.speaker("user turn", "❯")      # top-left sigil
      Indication.bracket("thought", "∵", "∴")   # first + last row
      Indication.rule("range", "·")             # every row
      Indication.plain("indented, no gutter")
      """
    },
    # --- Navigation/Layout widgets ---
    %{
      name: "Tabs",
      module: Demos.TabsDemo,
      category: :navigation,
      description:
        "Tabs component — horizontal tab bar with ←/→, Home/End, 1-9; " <>
          "content panels are parent-owned via active_index",
      complexity: :basic,
      tags: ["navigation", "tabs", "panels", "controlled"],
      code_snippet: """
      {:ok, tabs} =
        Tabs.init(
          id: "main-tabs",
          active_index: 0,
          focused: true,
          tabs: [
            %{id: :overview, label: "Overview"},
            %{id: :details, label: "Details"}
          ]
        )

      {tabs, _cmds} =
        Tabs.handle_event(%Event{type: :key, data: %{key: :right}}, tabs, %{})
      Tabs.render(tabs, %{})
      # parent switches content from tabs.active_index
      """
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
      description:
        "Scrollable viewport container (Display.Viewport) with keyboard scroll controls",
      complexity: :basic,
      tags: ["layout", "container", "scroll", "viewport"],
      code_snippet: """
      {:ok, vp} =
        Viewport.init(
          id: "scroll",
          children: items,
          visible_height: 10,
          scroll_top: 0,
          show_scrollbar: true
        )

      Viewport.render(vp, %{})
      """
    },
    # --- Chart/Visualization widgets ---
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
      name: "Harness Notice",
      module: Demos.HarnessNoticeDemo,
      category: :harness,
      description:
        "Footer honest-report channel: Notice (refusal/degradation) — " <>
          "nil / string / multi-line / list vocabulary",
      complexity: :basic,
      tags: ["harness", "notice", "footer", "report", "controlled"],
      code_snippet: """
      {:ok, n} = Notice.init(id: "notice", notice: "no block focused", width: 40)
      Notice.render(n, %{})

      # line vocabulary (nil → []; string → rows; list → flat concat)
      Notice.lines(["degraded", "composer disabled"], 40)
      """
    },
    %{
      name: "Harness Panels",
      module: Demos.HarnessPanelsDemo,
      category: :display,
      description:
        "Read-only harness projection panels: worktracks kanban, rules (hard vs soft), memory",
      complexity: :intermediate,
      tags: ["harness", "display", "kanban", "rules", "memory", "projection"],
      code_snippet: """
      {:ok, state} = WorktracksPanel.init(lanes: [
        %{name: "doing", items: [%{title: "Fold extract into board", status: "doing"}]}
      ])
      WorktracksPanel.render(state, %{})
      """
    },
    # --- Harness TEA blocks (migration §7: one demo per block kind) ---
    %{
      name: "Harness Message Block",
      module: Demos.HarnessMessageBlockDemo,
      category: :harness_chat_widgets,
      description:
        "Transcript message blocks as controlled Components: mirrored speaker sigils (user ❯ / assistant ❮), fold toggle, MCP toggle tool",
      complexity: :intermediate,
      tags: ["harness", "message", "transcript", "sigil", "controlled", "mcp"],
      code_snippet: """
      {:ok, s} =
        MessageBlock.init(
          id: "msg-1", role: :user, content: "hi",
          on_toggle: {:toggle_fold, "msg-1"}
        )

      MessageBlock.render(s, %{})  # root stamped id/attrs/on_click for MCP
      """
    },
    %{
      name: "Harness Thinking Stream",
      module: Demos.HarnessThinkingStreamDemo,
      category: :harness_chat_widgets,
      description:
        "Live shadow-cast reasoning: the dominating primitive holds the " <>
          "faintest row while newer lines fade up; per-char shadow fade; " <>
          "3 states (fully_collapsed/peek/expanded), click or z/enter/space",
      complexity: :advanced,
      tags: [
        "harness",
        "reasoning",
        "thinking",
        "prominence",
        "streaming",
        "shadow",
        "animated"
      ],
      code_snippet: """
      ShadowStream.render(%{
        primitive: "thinking", lines: reasoning, state: :peek,
        width: 60, id: "thinking", on_click: :cycle
      })
      # :fully_collapsed → :peek (shadow window) → :expanded (∵…∴ bracket)
      """
    },
    %{
      name: "Harness Overlay",
      module: Demos.HarnessOverlayDemo,
      category: :harness,
      description:
        "Picker, projection panels, and scrollable diff-expansion hosted as LayoutEngine children (AbsoluteLayer dialogs) over the transcript — the full-viewport overlay gap closed: no footer-grow",
      complexity: :advanced,
      tags: [
        "harness",
        "overlay",
        "picker",
        "panel",
        "full-viewport",
        "controlled",
        "mcp"
      ],
      code_snippet: """
      # overlays are just layout children -- no footer-grow, no refusal
      absolute_layer(transcript, [
        dialog_overlay(w, h, Picker.render(picker_state, %{available_width: w - 4}))
      ])
      """
    },
    %{
      name: "Harness FooterStack",
      module: Demos.HarnessFooterStackDemo,
      category: :harness,
      description:
        "The footer's honest-notice fit law: oversized groups clamped to a shrinking budget — drop order, protected channels never shed, budget-1 notice-wins",
      complexity: :advanced,
      tags: [
        "harness",
        "footer",
        "layout",
        "fit",
        "honest-notice",
        "controlled"
      ],
      code_snippet: """
      {:ok, fs} =
        FooterStack.init(
          groups: [status: s, lane: l, composer: c, notice: n],
          drop_order: [:composer_sep, :preview, :composer, :status],
          budget: rows
        )

      FooterStack.render(fs, %{})  # fits in view-time; lane/notice never shed
      """
    },
    %{
      name: "Harness Status Strip",
      module: Demos.HarnessStatusStripDemo,
      category: :harness,
      description:
        "The pinned status strip: phase vocabulary (thinking/running/responding/awaiting approval), tick-driven braille spinner, ALERT stall, charged-minimum absence",
      complexity: :intermediate,
      tags: ["harness", "status", "spinner", "phase", "alert", "controlled"],
      code_snippet: """
      {:ok, s} =
        StatusStrip.init(id: "status", status: status, spinner_frame: n)

      StatusStrip.render(s, %{})  # yields to silence when nothing is true
      """
    },
    %{
      name: "Harness Composer",
      module: Demos.HarnessComposerDemo,
      category: :harness,
      description:
        "The prompt composer on the TEA path: cursor park at the edit point (buffer cursor), WrapMap wrap/readline chords, placeholder, submit/refuse notices",
      complexity: :advanced,
      tags: ["harness", "composer", "cursor", "input", "wrap", "controlled"],
      code_snippet: """
      {:ok, c} = Composer.init(id: "composer", focused: true)
      rows = Composer.visual_lines(c, width)
      {row, col} = Composer.edit_point(c, width)  # -> root :cursor
      """
    },
    %{
      name: "Harness Choice Prompt",
      module: Demos.HarnessChoicePromptDemo,
      category: :harness,
      description:
        "The chevron confirm/cancel pair plus a free-text third way: [enter]/[escape] hints while idle, hints yield when typing (Enter submits, Esc clears), arrows walk confirm/cancel/input text-first",
      complexity: :advanced,
      tags: ["harness", "choice", "confirm", "input", "cursor", "controlled"],
      code_snippet: """
      {:ok, p} = ChoicePrompt.init(id: "choice", width: 44)
      {p, cmds} = ChoicePrompt.handle_event(key_event, p, %{})
      # cmds: {:component_event, id, :confirm | :cancel | {:submit, text}}
      ChoicePrompt.edit_point(p, 44)  # -> root :cursor (nil on option rows)
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
