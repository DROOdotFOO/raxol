defmodule Raxol.ScoreboardTest do
  @moduledoc """
  The scoreboard's byte metrics claim to measure what the rendering engine
  writes. `Raxol.Scoreboard.frames/2` calls the engine's stage functions in
  its own order, so a stage added to, removed from or reordered in the engine
  alone would make the scoreboard measure a frame the engine never draws.
  This drives a real engine through the same model sequence and requires the
  same bytes, frame by frame.
  """

  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Raxol.Core.Events.Event
  alias Raxol.Core.Runtime.Rendering.Engine
  alias Raxol.Playground.Demos.TableDemo

  @keys ~w(j j j j j s j j k b)

  # Stands in for the event dispatcher: serves the current model and no
  # plugin manager, as an app with no plugins loaded has.
  defmodule ModelDispatcher do
    use GenServer

    def start_link(model), do: GenServer.start_link(__MODULE__, model)

    @impl true
    def init(model), do: {:ok, model}

    @impl true
    def handle_call({:set_model, model}, _from, _model),
      do: {:reply, :ok, model}

    def handle_call(:get_render_context, _from, model),
      do: {:reply, {:ok, %{model: model, theme_id: nil}}, model}

    def handle_call(:get_plugin_manager, _from, model),
      do: {:reply, {:ok, nil}, model}

    @impl true
    def handle_cast(_view_tree_or_layout, model), do: {:noreply, model}
  end

  test "frames/2 produces the bytes the rendering engine writes for the same model sequence" do
    models = model_sequence(TableDemo, @keys)
    dispatcher = start_supervised!({ModelDispatcher, hd(models)})

    engine =
      start_supervised!(
        {Engine,
         app_module: TableDemo,
         dispatcher_pid: dispatcher,
         width: 120,
         height: 40,
         environment: :terminal},
        id: make_ref()
      )

    # The engine writes frames to its group leader; read them back per frame.
    {:ok, device} = StringIO.open("")
    Process.group_leader(engine, device)

    engine_frames =
      for model <- models do
        :ok = GenServer.call(dispatcher, {:set_model, model})
        :ok = GenServer.call(engine, :render_frame_sync)
        written = StringIO.flush(device)
        # Synchronized-output brackets wrap the payload only when the host
        # terminal supports them; the scoreboard counts the payload.
        String.replace(written, ["\e[?2026h", "\e[?2026l"], "")
      end

    scoreboard_frames = Raxol.Scoreboard.frames(TableDemo, @keys)

    assert length(engine_frames) == length(scoreboard_frames)

    for {{engine_frame, scoreboard_frame}, index} <-
          Enum.with_index(Enum.zip(engine_frames, scoreboard_frames)) do
      assert engine_frame == scoreboard_frame,
             "frame #{index}: engine wrote #{byte_size(engine_frame)} bytes, " <>
               "the scoreboard measured #{byte_size(scoreboard_frame)}"
    end
  end

  defp model_sequence(app, keys) do
    first = unwrap(app.init(%{}))

    Enum.scan(keys, first, fn key, model ->
      unwrap(
        app.update(%Event{type: :key, data: %{key: :char, char: key}}, model)
      )
    end)
    |> then(&[first | &1])
  end

  defp unwrap({model, _commands}), do: model
  defp unwrap(model), do: model
end
