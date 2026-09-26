defmodule Raxol.ExamplesRenderTest do
  @moduledoc """
  Every TEA app under `examples/` draws its first frame (#1129).

  The examples are the first thing a new user runs, and nothing compiled
  them: a constructor that drew nothing, or an option the DSL did not
  accept, blanked an example with no failing test. Each one is started by
  a headless session straight from its source file, with its
  subscriptions unarmed so the first frame is the `init/1` model's, and
  the frame must show something.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Raxol.Headless

  @examples "examples/**/*.{ex,exs}"
            |> Path.wildcard()
            |> Enum.filter(
              &(File.read!(&1) =~
                  ~r/^\s*use Raxol\.Core\.Runtime\.Application\b/m)
            )
            |> Enum.sort()

  # Examples whose first frame is blank for a cause outside the view DSL,
  # with that cause. An entry fails once its example draws, so it is
  # removed rather than left to hide a later regression.
  @known_blank %{
    "examples/components/accessibility/accessibility_demo.ex" =>
      "view/1 reads state.form_data, which the demo's struct does not " <>
        "define, and its root node's type, Raxol.UI.Components.AppContainer, " <>
        "names no module or layout type"
  }

  setup do
    case Process.whereis(Headless) do
      nil -> start_supervised!({Headless, [name: Headless]})
      _pid -> :ok
    end

    :ok
  end

  test "the examples are found, and every known-blank entry is one of them" do
    assert length(@examples) > 20
    assert Map.keys(@known_blank) -- @examples == []
  end

  for path <- @examples do
    @path path
    test "#{path} draws its first frame" do
      frame = first_frame(@path)

      case Map.fetch(@known_blank, @path) do
        {:ok, cause} ->
          assert frame == "",
                 "#{@path} draws now; remove it from @known_blank (#{cause})"

        :error ->
          assert frame != "", "#{@path} rendered a blank first frame"
      end
    end
  end

  # The examples' own compiler warnings are not this test's subject, and
  # would bury its output; they go to stderr, so capture it.
  defp first_frame(path) do
    id = :"example_#{System.unique_integer([:positive])}"

    {result, _stderr} =
      with_io(:stderr, fn ->
        Headless.start(path,
          id: id,
          width: 100,
          height: 30,
          subscriptions: false
        )
      end)

    assert {:ok, ^id} = result

    try do
      {{:ok, screen}, _stderr} =
        with_io(:stderr, fn -> Headless.screenshot(id) end)

      String.trim(screen)
    after
      Headless.stop(id)
    end
  end
end
