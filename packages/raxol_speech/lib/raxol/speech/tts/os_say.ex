defmodule Raxol.Speech.TTS.OsSay do
  @moduledoc """
  TTS backend using the operating system's speech command.

  - macOS: `say`
  - Linux: `espeak` (or `espeak-ng`)
  - Other: returns `{:error, :unsupported_platform}`

  Speech runs asynchronously via a spawned process. `stop/0` kills it.
  """

  @behaviour Raxol.Speech.TTS.Backend

  use Raxol.Core.Behaviours.BaseManager

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @max_text_length 10_000

  @impl Raxol.Speech.TTS.Backend
  def speak(text) when is_binary(text) do
    if byte_size(text) > @max_text_length do
      {:error, :text_too_long}
    else
      GenServer.call(__MODULE__, {:speak, sanitize_text(text)})
    end
  end

  @impl Raxol.Speech.TTS.Backend
  def stop do
    GenServer.call(__MODULE__, :stop)
  end

  @impl Raxol.Speech.TTS.Backend
  def speaking? do
    GenServer.call(__MODULE__, :speaking?)
  end

  # -- BaseManager --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(_opts) do
    {:ok, %{port: nil, os_cmd: detect_command()}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:speak, text}, _from, state) do
    state = kill_current(state)

    case state.os_cmd do
      nil ->
        {:reply, {:error, :unsupported_platform}, state}

      {cmd, args} ->
        # "--" sentinel prevents text starting with "-" from being parsed as flags
        port =
          Port.open({:spawn_executable, cmd}, [:binary, :exit_status, args: args ++ ["--", text]])

        {:reply, :ok, %{state | port: port}}
    end
  end

  def handle_manager_call(:stop, _from, state) do
    {:reply, :ok, kill_current(state)}
  end

  def handle_manager_call(:speaking?, _from, state) do
    {:reply, state.port != nil, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({port, {:exit_status, _}}, %{port: port} = state) do
    {:noreply, %{state | port: nil}}
  end

  def handle_manager_info({port, {:data, _}}, %{port: port} = state) do
    {:noreply, state}
  end

  def handle_manager_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    kill_current(state)
    :ok
  end

  # -- Private --

  defp kill_current(%{port: nil} = state), do: state

  defp kill_current(%{port: port} = state) do
    try do
      Port.close(port)
    catch
      :error, :badarg -> :ok
    end

    %{state | port: nil}
  end

  # Strip control characters (keep printable text, newlines, tabs)
  defp sanitize_text(text) do
    String.replace(text, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
  end

  defp detect_command do
    case :os.type() do
      {:unix, :darwin} ->
        case System.find_executable("say") do
          nil -> nil
          path -> {path, []}
        end

      {:unix, _} ->
        case System.find_executable("espeak-ng") do
          nil ->
            case System.find_executable("espeak") do
              nil -> nil
              path -> {path, []}
            end

          path ->
            {path, []}
        end

      _ ->
        nil
    end
  end
end
