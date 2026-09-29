defmodule Raxol.HeadlessResizeTest do
  @moduledoc """
  End-to-end: `Headless.send_resize/3` must reach app `update/2` and resize the Rendering Engine buffer.
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

    :ok = Headless.send_resize(id, 100, 30)

    {:ok, model} = Headless.get_model(id)
    assert model.resizes == 1
    assert model.width == 100
    assert model.height == 30

    {:ok, buffer} = Headless.get_buffer(id)
    assert Map.get(buffer, :width) == 100
    assert Map.get(buffer, :height) == 30

    :ok = Headless.send_resize(id, 66, 20)
    {:ok, model} = Headless.get_model(id)
    assert model.resizes == 2
    assert model.width == 66

    {:ok, buffer} = Headless.get_buffer(id)
    assert Map.get(buffer, :width) == 66
    assert Map.get(buffer, :height) == 20
  end

  test "send_resize on unknown session returns an error" do
    assert {:error, :not_found} = Headless.send_resize(:nope, 80, 24)
  end
end
