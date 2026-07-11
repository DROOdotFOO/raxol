defmodule Raxol.HeadlessResizeTest do
  @moduledoc """
  End-to-end regression test for the terminal resize chain:
  `Headless.send_resize/3` -> Dispatcher -> (a) app `update/2` sees
  `%Event{type: :resize}`, (b) Rendering Engine buffer is resized.
  """
  use ExUnit.Case, async: false

  alias Raxol.Headless

  defmodule ResizeApp do
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: %{width: 0, height: 0, resizes: 0}

    @impl true
    def update(message, model) do
      case message do
        %Raxol.Core.Events.Event{
          type: :resize,
          data: %{width: w, height: h}
        } ->
          {%{model | width: w, height: h, resizes: model.resizes + 1}, []}

        _ ->
          {model, []}
      end
    end

    @impl true
    def view(model) do
      Raxol.Core.Renderer.View.text(
        "#{model.width}x#{model.height} (#{model.resizes} resizes)"
      )
    end

    @impl true
    def subscriptions(_model), do: []
  end

  setup do
    pid =
      case Process.whereis(Headless) do
        nil ->
          start_supervised!({Headless, [name: Headless]})

        existing ->
          for id <- GenServer.call(existing, :list_sessions) do
            try do
              GenServer.call(existing, {:stop_session, id}, 2_000)
            catch
              _, _ -> :ok
            end
          end

          existing
      end

    {:ok, headless: pid}
  end

  defp wait_for_model(id, fun, retries \\ 40)

  defp wait_for_model(_id, _fun, 0), do: flunk("model never matched")

  defp wait_for_model(id, fun, retries) do
    {:ok, model} = Headless.get_model(id)

    if fun.(model) do
      model
    else
      Process.sleep(25)
      wait_for_model(id, fun, retries - 1)
    end
  end

  test "send_resize reaches app update/2 and resizes the engine buffer" do
    {:ok, id} =
      Headless.start(ResizeApp, id: :resize_e2e, width: 80, height: 24)

    on_exit(fn ->
      # Headless may already be gone if it was started via start_supervised!
      try do
        Headless.stop(:resize_e2e)
      catch
        :exit, _ -> :ok
      end
    end)

    # (a) App model sees the resize event
    :ok = Headless.send_resize(id, 100, 30)

    model = wait_for_model(id, fn m -> m.resizes == 1 end)
    assert model.width == 100
    assert model.height == 30

    # (b) Engine buffer adopts the new dimensions
    {:ok, buffer} = Headless.get_buffer(id)
    assert Map.get(buffer, :width) == 100
    assert Map.get(buffer, :height) == 30

    # A second resize also flows through
    :ok = Headless.send_resize(id, 66, 20)
    model = wait_for_model(id, fn m -> m.resizes == 2 end)
    assert model.width == 66

    {:ok, buffer} = Headless.get_buffer(id)
    assert Map.get(buffer, :width) == 66
    assert Map.get(buffer, :height) == 20
  end

  test "send_resize on unknown session returns an error" do
    assert {:error, :not_found} = Headless.send_resize(:nope, 80, 24)
  end
end
