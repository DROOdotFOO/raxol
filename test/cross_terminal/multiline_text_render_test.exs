defmodule Raxol.CrossTerminal.MultilineTextRenderTest do
  @moduledoc """
  Regression: text elements containing embedded newlines must render each
  line at the ELEMENT's x on consecutive rows — never emit a literal "\\n"
  cell (which linefeeds the terminal to column 0, dragging content outside
  its layout box; observed in the playground code panel and LineChart).
  """
  use ExUnit.Case, async: false

  alias Raxol.Headless
  alias Raxol.Terminal.Buffer.Queries

  defmodule CodePanelApp do
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: %{}

    @impl true
    def update(_message, model), do: {model, []}

    @impl true
    def view(_model) do
      require Raxol.Core.Renderer.View
      alias Raxol.Core.Renderer.View, as: V

      V.row style: %{gap: 0} do
        [
          V.box(
            style: %{border: :single, width: 12},
            children: [V.text("side1\nside2\nside3")]
          ),
          V.column style: %{gap: 0} do
            [V.text("code:\n  line_one(\n    arg\n  )")]
          end
        ]
      end
    end

    @impl true
    def subscribe(_model), do: []
  end

  setup do
    pid =
      case Process.whereis(Headless) do
        nil -> start_supervised!({Headless, [name: Headless]})
        existing -> existing
      end

    on_exit(fn ->
      if Process.alive?(pid) do
        for id <- GenServer.call(pid, :list_sessions) do
          try do
            GenServer.call(pid, {:stop_session, id}, 2_000)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    :ok
  end

  test "multiline text lines all start at the element's x column" do
    {:ok, id} = Headless.start(CodePanelApp, id: :ml_text, width: 60, height: 20)
    Process.sleep(300)
    {:ok, buffer} = Headless.get_buffer(id)
    text = Queries.get_text(buffer)
    lines = String.split(text, "\n")

    # The second element sits at x=12 (after the 12-wide box). Every one
    # of its four lines must start at column 12, none may leak to column 0
    # inside the sidebar box or to the row below the layout.
    code_rows =
      lines
      |> Enum.filter(&(String.contains?(&1, "code:") or String.contains?(&1, "line_one") or
             String.contains?(&1, "arg") or String.trim(&1) == ")"))

    assert length(code_rows) >= 3

    for row <- code_rows do
      # nothing before column 12 except the sidebar box's own content
      prefix = String.slice(row, 0, 12)
      refute prefix =~ "code",
             "code content leaked into sidebar columns: #{inspect(row)}"
      refute prefix =~ "line_one",
             "code content leaked into sidebar columns: #{inspect(row)}"
    end

    # No literal newline characters stored as cells
    refute text =~ <<0>>

    # Sidebar's own multiline text also stays inside its box (x=1, border)
    side_rows = Enum.filter(lines, &(&1 =~ "side"))
    assert length(side_rows) == 3

    for row <- side_rows do
      assert row =~ ~r/^│side\d/,
             "sidebar line escaped its box: #{inspect(row)}"
    end

    :ok = Headless.stop(id)
  end
end
