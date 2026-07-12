defmodule Raxol.CrossTerminal.HeadlessGoldenTest do
  @moduledoc """
  Boots a real TEA app headless and pins its rendered text grid across
  boot, key events, and re-render — an end-to-end pipeline regression net.
  """
  use ExUnit.Case, async: false

  alias Raxol.Headless

  defmodule GoldenApp do
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: %{count: 0, panel: :a}

    @impl true
    def update(message, model) do
      case message do
        %Raxol.Core.Events.Event{type: :key, data: %{key: :tab}} ->
          {%{model | panel: :b}, []}

        %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "+"}} ->
          {%{model | count: model.count + 1}, []}

        _ ->
          {model, []}
      end
    end

    @impl true
    def view(model) do
      Raxol.Core.Renderer.View.column(
        children: [
          Raxol.Core.Renderer.View.text("Count: #{model.count}"),
          Raxol.Core.Renderer.View.text("Panel: #{model.panel}")
        ]
      )
    end

    @impl true
    def subscriptions(_model), do: []
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

  test "initial render matches golden" do
    {:ok, id} = Headless.start(GoldenApp, id: :golden_initial)
    {:ok, text} = Headless.screenshot(id)

    assert text =~ "Count: 0"
    assert text =~ "Panel: a"
    :ok = Headless.stop(id)
  end

  test "key event updates model and re-renders" do
    {:ok, id} = Headless.start(GoldenApp, id: :golden_keys)

    {:ok, text} = Headless.send_key_and_screenshot(id, :tab)
    assert text =~ "Panel: b"

    {:ok, text} = Headless.send_key_and_screenshot(id, "+")
    assert text =~ "Count: 1"

    :ok = Headless.stop(id)
  end

  test "model state matches what the screen shows" do
    {:ok, id} = Headless.start(GoldenApp, id: :golden_model)
    {:ok, _} = Headless.send_key_and_screenshot(id, "+")
    {:ok, _} = Headless.send_key_and_screenshot(id, "+")

    {:ok, model} = Headless.get_model(id)
    {:ok, text} = Headless.screenshot(id)

    assert model.count == 2
    assert text =~ "Count: 2"
    :ok = Headless.stop(id)
  end
end
