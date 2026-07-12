defmodule Raxol.CrossTerminal.BoxDimensionsTest do
  @moduledoc """
  Regression tests for layout-engine box sizing: `box style: %{width: N}`
  rendering full-bleed, and View DSL padding (normalized to a 4-tuple)
  being silently dropped. Uses the real playground TextInput demo at a
  large screen size.
  """
  use ExUnit.Case, async: false

  alias Raxol.Headless
  alias Raxol.Terminal.Buffer.Queries

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

  defp rendered_lines(id) do
    {:ok, buffer} = Headless.get_buffer(id)

    buffer
    |> Queries.get_text()
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
  end

  test "box with explicit style width stays at that width on a wide screen" do
    {:ok, id} =
      Headless.start(Raxol.Playground.Demos.TextInputDemo,
        id: :box_dims,
        width: 200,
        height: 60
      )

    Process.sleep(300)
    lines = rendered_lines(id)

    border_lines =
      Enum.filter(
        lines,
        &(String.starts_with?(&1, "┌") or String.starts_with?(&1, "└"))
      )

    # Demo declares two 40-wide boxes; the text_input component adds its own
    # small bordered box. No bordered line may be full-bleed (200 cols), and
    # the demo boxes must be exactly 40.
    assert border_lines != []

    for line <- border_lines do
      assert String.length(line) < 200,
             "border line rendered full-bleed: #{inspect(String.slice(line, 0, 50))}..."
    end

    assert Enum.count(border_lines, &(String.length(&1) == 40)) >= 2

    :ok = Headless.stop(id)
  end

  test "box padding insets content from the border" do
    {:ok, id} =
      Headless.start(Raxol.Playground.Demos.TextInputDemo,
        id: :box_pad,
        width: 200,
        height: 60
      )

    Process.sleep(300)
    lines = rendered_lines(id)

    # The input box has horizontal padding {0,1,0,1}: content line reads
    # "│ (type to enter text)_ ..." — space between border and text.
    content_line =
      Enum.find(lines, &String.contains?(&1, "(type to enter text)"))

    assert content_line != nil
    assert content_line =~ "│ (type",
           "padding not applied: #{inspect(String.slice(content_line, 0, 30))}"

    # No vertical padding: the single-line input box is exactly 3 rows —
    # the row above the content is the top border, not a padded blank row.
    content_idx =
      Enum.find_index(lines, &String.contains?(&1, "(type to enter text)"))

    assert Enum.at(lines, content_idx - 1) |> String.starts_with?("┌")
    assert Enum.at(lines, content_idx + 1) |> String.starts_with?("└")

    :ok = Headless.stop(id)
  end
end
