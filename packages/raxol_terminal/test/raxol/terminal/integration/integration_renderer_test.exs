defmodule Raxol.Terminal.Integration.RendererTest do
  # Toggles the global :terminal_test_mode flag.
  use ExUnit.Case, async: false

  alias Raxol.Terminal.Integration
  alias Raxol.Terminal.Integration.Renderer
  alias Raxol.Terminal.Integration.State

  # These run the real-terminal branch, which calls the termbox2 NIF. No
  # tb_init/0 happens here, so termbox itself rejects every call with
  # TB_ERR_NOT_INIT; the NIF discards that code and returns its own success
  # value, which is what the renderer has to classify.
  @moduletag :unix_only

  setup do
    previous = Application.fetch_env(:raxol, :terminal_test_mode)
    Application.put_env(:raxol, :terminal_test_mode, false)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:raxol, :terminal_test_mode, value)
        :error -> Application.delete_env(:raxol, :terminal_test_mode)
      end
    end)

    %{state: %State{}}
  end

  test "move_cursor/3 returns :ok", %{state: state} do
    assert Renderer.move_cursor(state, 10, 5) == :ok
  end

  test "clear_screen/1 returns :ok", %{state: state} do
    assert Renderer.clear_screen(state) == :ok
  end

  test "Integration.set_title/2 stores the title", %{state: state} do
    # The NIF writes OSC 0 straight to the BEAM's stdout, so reset the
    # title to empty afterwards: terminals then fall back to their default.
    titled = Integration.set_title(state, "raxol")
    assert Integration.get_title(titled) == "raxol"

    assert Integration.get_title(Integration.set_title(titled, "")) == ""
  end
end
