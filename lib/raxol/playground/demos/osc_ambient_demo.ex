defmodule Raxol.Playground.Demos.OscAmbientDemo do
  @moduledoc """
  Playground demo: OSC 9 desktop notification, OSC 9;4 taskbar/dock
  progress, and OSC 22 pointer shape.

  These are host-terminal features, not something Raxol renders itself.
  Ghostty, iTerm2, WezTerm, and Windows Terminal draw the dock/taskbar
  progress bar from OSC 9;4; most other terminals (including many Linux
  emulators) silently ignore all three sequences. This demo always emits
  them and trusts the terminal to honor or drop them -- there is no
  capability detection here.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Playground.DemoHelpers
  alias Raxol.Terminal.AdvancedFeatures

  @tick_ms 200
  @step 4
  @max_progress 100
  @bar_width 30
  @pointer_shapes ["default", "text", "pointer", "wait", "crosshair"]

  @impl true
  def init(_context) do
    %{status: :idle, progress: 0, pointer_idx: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match(" ") ->
        toggle_running(model)

      key_match("r") ->
        {reset(model), [clear_progress_command()]}

      key_match("e") ->
        set_status(model, :error)

      key_match("w") ->
        set_status(model, :warning)

      key_match("c") ->
        cycle_pointer(model)

      :tick when model.status == :running ->
        advance(model)

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    filled = round(model.progress / @max_progress * @bar_width)
    empty = @bar_width - filled
    bar = String.duplicate("#", filled) <> String.duplicate(".", empty)
    shape = Enum.at(@pointer_shapes, model.pointer_idx)

    column style: %{gap: 1} do
      [
        text("OSC Ambient Demo", style: [:bold]),
        text("Desktop notification + taskbar progress + pointer shape",
          style: [:dim]
        ),
        divider(),
        progress(value: model.progress, max: @max_progress),
        text("[#{bar}] #{model.progress}%"),
        text("Task: #{status_label(model.status)}",
          fg: status_color(model.status)
        ),
        text("Pointer shape: #{shape}"),
        divider(),
        box style: %{border: :single, padding: 1, width: 56} do
          column style: %{gap: 0} do
            [
              text("Host-terminal features -- may do nothing here.",
                style: [:bold]
              ),
              text("OSC 9;4 taskbar progress: Ghostty, iTerm2, WezTerm,"),
              text("Windows Terminal. Most other terminals ignore it."),
              text("No capability detection is performed.")
            ]
          end
        end,
        text(
          "[space] start/pause  [e] error  [w] warning  [c] pointer  [r] reset",
          style: [:dim]
        )
      ]
    end
  end

  @impl true
  def subscribe(model) do
    if model.status == :running do
      [subscribe_interval(@tick_ms, :tick)]
    else
      []
    end
  end

  defp toggle_running(%{status: :done} = model), do: {model, []}

  defp toggle_running(%{status: :running} = model) do
    {%{model | status: :paused}, []}
  end

  defp toggle_running(model) do
    new_model = %{model | status: :running}
    {new_model, [progress_command(new_model)]}
  end

  defp set_status(%{status: :done} = model, _status), do: {model, []}

  defp set_status(model, status) do
    new_model = %{model | status: status}
    {new_model, [progress_command(new_model)]}
  end

  defp cycle_pointer(model) do
    new_idx = DemoHelpers.cycle_next(model.pointer_idx, length(@pointer_shapes))
    shape = Enum.at(@pointer_shapes, new_idx)
    {%{model | pointer_idx: new_idx}, [pointer_command(shape)]}
  end

  defp reset(model), do: %{model | status: :idle, progress: 0}

  defp advance(model) do
    new_progress = min(model.progress + @step, @max_progress)

    if new_progress >= @max_progress do
      new_model = %{model | progress: @max_progress, status: :done}
      {new_model, [progress_command(new_model), notify_command()]}
    else
      new_model = %{model | progress: new_progress}
      {new_model, [progress_command(new_model)]}
    end
  end

  # snippet:start
  defp progress_command(model) do
    state = progress_state(model.status)

    Directive.spawn_task(fn ->
      IO.write(AdvancedFeatures.report_progress(state, model.progress))
      :ok
    end)
  end

  # snippet:end

  defp clear_progress_command do
    Directive.spawn_task(fn ->
      IO.write(AdvancedFeatures.clear_progress())
      :ok
    end)
  end

  defp notify_command do
    Directive.spawn_task(fn ->
      IO.write(AdvancedFeatures.notify("Playground task complete"))
      :ok
    end)
  end

  defp pointer_command(shape) do
    Directive.spawn_task(fn ->
      IO.write(AdvancedFeatures.set_pointer_shape(shape))
      :ok
    end)
  end

  defp progress_state(:error), do: :error
  defp progress_state(:warning), do: :warning
  defp progress_state(_), do: :set

  defp status_label(:idle), do: "idle"
  defp status_label(:running), do: "running"
  defp status_label(:paused), do: "paused"
  defp status_label(:error), do: "error"
  defp status_label(:warning), do: "warning"
  defp status_label(:done), do: "done"

  defp status_color(:error), do: :red
  defp status_color(:warning), do: :yellow
  defp status_color(:done), do: :green
  defp status_color(:running), do: :cyan
  defp status_color(_), do: :white
end
