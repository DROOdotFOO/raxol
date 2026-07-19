defmodule Raxol.Playground.DemoRenderTest do
  @moduledoc """
  End-to-end render regression test for every Catalog demo.

  Mounts each demo through the real Lifecycle/Engine/Renderer pipeline
  using `Raxol.Headless`, captures a text screenshot, and asserts the
  output is not vacuously empty. Built specifically to catch the failure
  mode where a column or row receives a runtime-built children list and
  silently renders blank (because the macro expansion drops the children),
  or where a widget renders its box border but loses its label.

  Each demo is required to:

    * render its title in the first non-empty line (catches mount failures)
    * have at least @min_content_lines distinct lines of non-decoration text
      (catches collapsed columns where children become invisible)

  Individual demos can opt-in to a stricter `:expected` substring check by
  adding an entry to @expected_text. Substrings are case-sensitive.
  """

  # `capture_log: true` swallows the Lifecycle/Engine/Buffer.Writer debug
  # stream that would otherwise drown the failure messages.
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Raxol.Headless
  alias Raxol.Playground.Catalog

  # Wait for the demo's first render frame to settle before snapping.
  @initial_settle_ms 150

  # Minimum number of "content" lines (non-blank, not made entirely of
  # divider/border characters) every demo must produce. Empirically every
  # working demo emits ten or more rows; broken ones (the bug that
  # triggered this test) emit two or three.
  @min_content_lines 6

  # Minimum number of "visible" cells in the rendered buffer — counts both
  # cells with non-space characters AND cells with a non-default background
  # color. Catches color-only widgets like Heatmap where the screenshot text
  # capture sees nothing but the buffer has a fully painted region.
  @min_visible_cells 30

  # Per-demo substring checks. Each listed string must appear somewhere
  # across the union of frames we capture (initial + after each key drive).
  # Strings should be content the WIDGET produces, not its footer hints —
  # "[o] open modal" is the footer, "Confirm Action" is the widget itself.
  @expected_text %{
    "Button" => ["Primary", "Secondary", "Reset"],
    "TextInput" => ["Type here", "already filled", "chars:"],
    "Checkbox" => [
      "Enable notifications",
      "Dark mode",
      "Auto-save",
      "Show line numbers",
      "Word wrap"
    ],
    "TextArea" => ["Hello, world!", "Edit me with arrows"],
    "Modal" => ["Confirm Action", "Are you sure", "Confirm", "Cancel"],
    "Tabs" => ["Overview", "Details", "Settings", "Help"],
    "Container" => ["Item 01", "Item 02"],
    "SelectList" => ["Elixir", "Rust"],
    "RadioGroup" => ["Theme", "Size", "Speed"],
    "Menu" => ["File", "Edit", "View"],
    "Tree" => ["src", "lib"],
    "Table" => ["Raxol", "Elixir"],
    "PasswordField" => ["PasswordField", "interactive", "placeholder", "disabled"],
    "CodeBlock" => ["defmodule", "Greeter"],
    "StatusBar" => ["Mode", "NORMAL"]
  }

  # Per-demo key sequences to exercise state changes that reveal more
  # content (e.g. Modal's "Confirm Action" panel only appears after `o`).
  # Each entry is a list of keys to send one at a time, with a screenshot
  # after each. The union of frames is checked against @expected_text.
  # Keys can be strings (single chars) or atoms (special keys).
  @key_drives %{
    "Modal" => ["o"],
    # SelectList is always-open; drive nav + select instead of invented "o" toggle
    "SelectList" => [:down, :enter],
    # open File submenu so child labels appear
    "Menu" => [:enter],
    "Tree" => ["e"],
    "Tabs" => ["l", "3"],
    "Checkbox" => ["j", " "]
  }

  setup_all do
    # The Headless GenServer is started by the application supervisor in
    # prod/dev. Tests start with an empty supervision tree, so bring it up
    # ourselves and let ExUnit own its lifecycle. Reuse the singleton if another
    # module already started it.
    case start_supervised({Headless, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    # Use a unique session id per test so concurrent runs don't collide.
    id = :"demo_render_#{System.unique_integer([:positive])}"
    on_exit(fn -> safe_stop(id) end)
    {:ok, id: id}
  end

  for component <- Catalog.list_components() do
    @component component

    @tag demo: @component.name
    test "#{@component.name} renders non-empty output through full pipeline", %{
      id: id
    } do
      assert {:ok, ^id} =
               Headless.start(@component.module, id: id, width: 80, height: 24)

      # Let the Engine push its first frame through the pipeline.
      Process.sleep(@initial_settle_ms)

      assert {:ok, initial_text} = Headless.screenshot(id)
      assert {:ok, buffer} = Headless.get_buffer(id)

      # Phase 1: baseline. The initial frame must have substantive content
      # in either the text screenshot OR the raw buffer. Pure-color widgets
      # like Heatmap render whitespace cells with colored backgrounds, so
      # the text capture sees an empty region; the buffer cell-count check
      # catches the visible paint.
      lines = String.split(initial_text, "\n")
      content_lines = Enum.filter(lines, &content_line?/1)
      visible_cells = count_visible_cells(buffer)

      enough_text = length(content_lines) >= @min_content_lines
      enough_paint = visible_cells >= @min_visible_cells

      assert enough_text or enough_paint,
             header(@component.name) <>
               "rendered too sparsely: " <>
               "#{length(content_lines)} content lines (need #{@min_content_lines}), " <>
               "#{visible_cells} visible cells (need #{@min_visible_cells}). " <>
               "This usually means a column or row dropped its children.\n\n" <>
               "Rendered output:\n\n" <>
               numbered(lines)

      # Phase 2: key-driven coverage. Drive the keys this demo's footer
      # advertises and collect the union of all rendered frames so the
      # @expected_text check can match content that's only reachable after
      # a state transition (e.g. ModalDemo's "Confirm Action" panel).
      union_text =
        @key_drives
        |> Map.get(@component.name, [])
        |> Enum.reduce(initial_text, fn key, acc ->
          {:ok, frame} = Headless.send_key_and_screenshot(id, key)
          acc <> "\n---\n" <> frame
        end)

      # Phase 3: per-demo content assertions. Each needle must appear in
      # at least one frame from the union.
      for needle <- Map.get(@expected_text, @component.name, []) do
        assert String.contains?(union_text, needle),
               header(@component.name) <>
                 "missing expected substring #{inspect(needle)} " <>
                 "across all driven frames. " <>
                 "Driven keys: #{inspect(Map.get(@key_drives, @component.name, []))}\n\n" <>
                 "Last frame:\n\n" <>
                 numbered(String.split(union_text, "\n"))
      end

      # Markdown rendered mode must not leak * _ ` markers
      if @component.name == "Markdown" do
        refute Regex.match?(~r/`[^`\n]+`/, initial_text),
               header(@component.name) <>
                 "literal backtick code markers leaked into rendered output.\n\n" <>
                 "Rendered output:\n\n" <> numbered(lines)

        refute Regex.match?(~r/\*[^*\s][^*\n]*\*/, initial_text),
               header(@component.name) <>
                 "literal *bold*/*em* asterisk markers leaked into rendered output " <>
                 "(bullet prefixes like \"  * \" are fine; a closed *word* pair is not).\n\n" <>
                 "Rendered output:\n\n" <> numbered(lines)

        refute Regex.match?(
                 ~r/(?<![[:alnum:]])_[^_\s][^_\n]*_(?![[:alnum:]])/,
                 initial_text
               ),
               header(@component.name) <>
                 "literal _em_ underscore markers leaked into rendered output.\n\n" <>
                 "Rendered output:\n\n" <> numbered(lines)
      end
    end
  end

  # --- Helpers ---

  # A "content" line is one that has at least three non-whitespace,
  # non-decoration characters. Dividers (`---`), box-drawing lines, and
  # padding count as decoration.
  defp content_line?(line) do
    stripped =
      line
      |> String.trim()
      |> String.replace(
        ~r/[\-\─\━\━\═\│\┃\━\─\┌\┐\└\┘\├\┤\┬\┴\┼\╭\╮\╯\╰\║\╔\╗\╚\╝\╠\╣\╦\╩\╬\=\.\*\#]+/,
        ""
      )

    String.length(stripped) >= 3
  end

  defp header(name), do: "[#{name}] "

  defp numbered(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {line, i} ->
      "  #{String.pad_leading(Integer.to_string(i), 2)} | #{line}"
    end)
  end

  # Cells the user can actually see: anything with a non-space character
  # or a non-default background color (paints whitespace).
  defp count_visible_cells(buffer) do
    buffer.cells
    |> List.flatten()
    |> Enum.count(&cell_visible?/1)
  end

  defp cell_visible?(%{char: char, style: %{background: bg}}) do
    has_char = char not in [" ", "", nil]
    has_bg = bg != nil and bg != :default
    has_char or has_bg
  end

  defp cell_visible?(_), do: false

  defp safe_stop(id) do
    try do
      Headless.stop(id)
    catch
      :exit, _ -> :ok
    end

    :ok
  end
end
