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

  alias Raxol.Core.FocusManager
  alias Raxol.Core.FocusManager.FocusServer
  alias Raxol.Headless

  @examples "examples/**/*.{ex,exs}"
            |> Path.wildcard()
            |> Enum.filter(
              &(File.read!(&1) =~
                  ~r/^\s*use Raxol\.Core\.Runtime\.Application\b/m)
            )
            |> Enum.sort()

  setup do
    case Process.whereis(Headless) do
      nil -> start_supervised!({Headless, [name: Headless]})
      _pid -> :ok
    end

    restore_focus_on_exit()
  end

  # The focus server is node-global, and while it holds focusables the
  # runtime's dispatcher turns every Tab into a focus change for any app
  # on the node. An example that registers focusables in `init/1` (the
  # accessibility demo does) must not leave them behind for the tests
  # that run after this module: stop the server if the example started
  # it, or unregister what the example added if it was already running.
  defp restore_focus_on_exit do
    before = focusable_ids()

    on_exit(fn ->
      case {before, Process.whereis(FocusServer)} do
        {_before, nil} ->
          :ok

        {nil, pid} ->
          GenServer.stop(pid, :normal)

        {ids, _pid} ->
          Enum.each(
            focusable_ids() -- ids,
            &FocusManager.unregister_focusable/1
          )
      end
    end)
  end

  defp focusable_ids do
    case Process.whereis(FocusServer) do
      nil ->
        nil

      pid ->
        pid
        |> :sys.get_state()
        |> Map.fetch!(:focusable_components)
        |> Map.keys()
    end
  end

  test "the examples are found" do
    assert length(@examples) > 20
  end

  for path <- @examples do
    @path path
    test "#{path} draws its first frame" do
      {frame, compile_output} = first_frame(@path)

      assert undefined_calls(compile_output) == [],
             "#{@path} calls a function or module that does not exist"

      assert frame != "", "#{@path} rendered a blank first frame"
    end
  end

  # Compiling an example warns, but does not fail, when it calls something
  # that does not exist; the call then raises only when that path runs,
  # which a first frame may never reach.
  defp undefined_calls(compile_output) do
    compile_output
    |> String.split("\n")
    |> Enum.filter(&(&1 =~ ~r/is undefined or private|is undefined \(module/))
  end

  # The examples' other compiler warnings are not this test's subject, and
  # would bury its output; they go to stderr, so capture it and hand it back.
  defp first_frame(path) do
    id = :"example_#{System.unique_integer([:positive])}"

    {result, compile_output} =
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

      {String.trim(screen), compile_output}
    after
      Headless.stop(id)
    end
  end
end
