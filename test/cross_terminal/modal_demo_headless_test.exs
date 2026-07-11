defmodule Raxol.CrossTerminal.ModalDemoHeadlessTest do
  @moduledoc """
  End-to-end coverage for `Raxol.Playground.Demos.ModalDemo` (acceptance
  criterion e): boots the real demo headless, opens the modal, and checks
  that it renders as a true dialog -- centered on top, background text
  still present and unmoved, dimmed behind it.
  """
  use ExUnit.Case, async: false

  alias Raxol.Headless

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

  defp cell_at(buffer, x, y), do: buffer.cells |> Enum.at(y) |> Enum.at(x)

  test "modal box renders centered on top, background text stays visible" do
    {:ok, id} =
      Headless.start(Raxol.Playground.Demos.ModalDemo, id: :modal_demo_e)

    {:ok, closed_text} = Headless.screenshot(id)
    assert closed_text =~ "Background content (does not move):"
    assert closed_text =~ "Modal Demo"
    refute closed_text =~ "Confirm Action"

    :ok = Headless.send_key(id, "o")
    Process.sleep(50)

    {:ok, open_text} = Headless.screenshot(id)
    # background is still present, unobstructed above/around the dialog
    assert open_text =~ "Background content (does not move):"
    assert open_text =~ "Modal Demo"
    # the dialog itself rendered
    assert open_text =~ "Confirm Action"
    assert open_text =~ "Are you sure you want to proceed?"

    :ok = Headless.stop(id)
  end

  test "background text cells are byte-identical open vs closed (no reflow)" do
    {:ok, id} =
      Headless.start(Raxol.Playground.Demos.ModalDemo, id: :modal_demo_reflow)

    {:ok, closed_buffer} = Headless.get_buffer(id)

    :ok = Headless.send_key(id, "o")
    Process.sleep(50)
    {:ok, open_buffer} = Headless.get_buffer(id)

    for y <- 0..3, x <- 0..35 do
      closed_cell = cell_at(closed_buffer, x, y)
      open_cell = cell_at(open_buffer, x, y)

      assert closed_cell.char == open_cell.char,
             "cell (#{x}, #{y}) moved: #{inspect(closed_cell.char)} -> #{inspect(open_cell.char)}"
    end

    :ok = Headless.stop(id)
  end

  test "background is dimmed while the modal is open, and un-dims on close" do
    {:ok, id} =
      Headless.start(Raxol.Playground.Demos.ModalDemo, id: :modal_demo_dim)

    {:ok, closed_buffer} = Headless.get_buffer(id)
    closed_title_cell = cell_at(closed_buffer, 0, 0)
    assert closed_title_cell.char == "M"
    assert closed_title_cell.style.foreground == :white

    :ok = Headless.send_key(id, "o")
    Process.sleep(50)
    {:ok, open_buffer} = Headless.get_buffer(id)
    open_title_cell = cell_at(open_buffer, 0, 0)
    assert open_title_cell.char == "M"
    assert open_title_cell.style.foreground == {140, 140, 140}

    :ok = Headless.send_key(id, "n")
    Process.sleep(50)
    {:ok, closed_again_buffer} = Headless.get_buffer(id)
    closed_again_title_cell = cell_at(closed_again_buffer, 0, 0)
    assert closed_again_title_cell.style.foreground == :white

    :ok = Headless.stop(id)
  end
end
