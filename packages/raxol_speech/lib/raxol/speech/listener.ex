defmodule Raxol.Speech.Listener do
  @moduledoc """
  Mic capture via an OS audio recording command (sox/rec).

  Push-to-talk model: `start_recording/0` spawns a Port running
  the record command, `stop_recording/0` closes the Port and sends
  the captured audio to the Recognizer for transcription.

  ## Options

    * `:record_command` - custom record command (default: auto-detected sox/rec)
    * `:sample_rate` - audio sample rate (default: 16000)
    * `:dispatcher_pid` - where to send recognized events (optional)
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Speech.{InputAdapter, Recognizer}

  @default_sample_rate 16000
  # 5 minutes max recording, ~9.6MB at 16kHz/16-bit/mono
  @default_max_duration_ms 5 * 60 * 1000
  # 10MB max audio buffer
  @default_max_bytes 10 * 1024 * 1024

  defstruct [
    :port,
    :record_cmd,
    :dispatcher_pid,
    :max_duration_ms,
    :max_bytes,
    :duration_timer,
    audio_chunks: [],
    audio_size: 0
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start recording from the microphone."
  @spec start_recording() :: :ok | {:error, term()}
  def start_recording do
    GenServer.call(__MODULE__, :start_recording)
  end

  @doc "Stop recording and transcribe the captured audio."
  @spec stop_recording() :: {:ok, String.t()} | {:error, term()}
  def stop_recording do
    GenServer.call(__MODULE__, :stop_recording, 30_000)
  end

  @doc "Returns whether the listener is currently recording."
  @spec recording?() :: boolean()
  def recording? do
    GenServer.call(__MODULE__, :recording?)
  end

  # -- GenServer --

  @allowed_record_binaries ~w(sox rec arecord parecord ffmpeg)

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    sample_rate = Keyword.get(opts, :sample_rate, @default_sample_rate)

    record_cmd =
      case Keyword.get(opts, :record_command) do
        nil ->
          detect_record_command(sample_rate)

        {cmd, args} = tuple when is_binary(cmd) and is_list(args) ->
          validate_record_command(tuple)

        _ ->
          nil
      end

    dispatcher_pid = Keyword.get(opts, :dispatcher_pid)
    max_duration_ms = Keyword.get(opts, :max_duration_ms, @default_max_duration_ms)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    {:ok,
     %__MODULE__{
       record_cmd: record_cmd,
       dispatcher_pid: dispatcher_pid,
       max_duration_ms: max_duration_ms,
       max_bytes: max_bytes
     }}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:start_recording, _from, %{port: port} = state) when port != nil do
    {:reply, {:error, :already_recording}, state}
  end

  def handle_manager_call(:start_recording, _from, state) do
    case state.record_cmd do
      nil ->
        {:reply, {:error, :no_record_command}, state}

      {cmd, args} ->
        port = Port.open({:spawn_executable, cmd}, [:binary, :exit_status, args: args])
        timer = Process.send_after(self(), :max_duration_reached, state.max_duration_ms)

        {:reply, :ok,
         %{state | port: port, audio_chunks: [], audio_size: 0, duration_timer: timer}}
    end
  end

  def handle_manager_call(:stop_recording, _from, %{port: nil} = state) do
    {:reply, {:error, :not_recording}, state}
  end

  def handle_manager_call(:stop_recording, _from, state) do
    if state.duration_timer, do: Process.cancel_timer(state.duration_timer)
    close_port(state.port)

    audio = state.audio_chunks |> Enum.reverse() |> IO.iodata_to_binary()
    state = %{state | port: nil, audio_chunks: [], audio_size: 0, duration_timer: nil}

    # Transcribe
    result =
      if byte_size(audio) > 0 do
        case Recognizer.recognize(audio) do
          {:ok, text} ->
            maybe_dispatch(text, state.dispatcher_pid)
            {:ok, text}

          error ->
            error
        end
      else
        {:error, :no_audio}
      end

    {:reply, result, state}
  end

  def handle_manager_call(:recording?, _from, state) do
    {:reply, state.port != nil, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({port, {:data, chunk}}, %{port: port} = state) do
    new_size = state.audio_size + byte_size(chunk)

    if new_size > state.max_bytes do
      # Max size reached -- stop recording to prevent OOM
      require Logger

      Logger.warning(
        "Listener: max audio buffer size (#{state.max_bytes} bytes) reached, stopping recording"
      )

      close_port(state.port)
      {:noreply, %{state | port: nil}}
    else
      {:noreply, %{state | audio_chunks: [chunk | state.audio_chunks], audio_size: new_size}}
    end
  end

  def handle_manager_info({port, {:exit_status, _}}, %{port: port} = state) do
    {:noreply, %{state | port: nil}}
  end

  def handle_manager_info(:max_duration_reached, %{port: nil} = state) do
    {:noreply, %{state | duration_timer: nil}}
  end

  def handle_manager_info(:max_duration_reached, state) do
    require Logger

    Logger.warning(
      "Listener: max recording duration (#{state.max_duration_ms}ms) reached, stopping recording"
    )

    close_port(state.port)
    {:noreply, %{state | port: nil, duration_timer: nil}}
  end

  def handle_manager_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.duration_timer, do: Process.cancel_timer(state.duration_timer)
    if state.port, do: close_port(state.port)
    :ok
  end

  # -- Private --

  defp close_port(port) do
    try do
      Port.close(port)
    catch
      :error, :badarg -> :ok
    end
  end

  defp validate_record_command({cmd, args}) do
    basename = Path.basename(cmd)

    if basename in @allowed_record_binaries and File.exists?(cmd) do
      {cmd, args}
    else
      require Logger
      Logger.warning("Rejected record command: #{cmd} (not in allowed list or does not exist)")
      nil
    end
  end

  defp detect_record_command(sample_rate) do
    case :os.type() do
      {:unix, _} ->
        wav_args = ["-d", "-t", "wav", "-r", "#{sample_rate}", "-c", "1", "-b", "16", "-"]

        case System.find_executable("sox") do
          nil ->
            case System.find_executable("rec") do
              nil -> nil
              path -> {path, wav_args}
            end

          path ->
            {path, wav_args}
        end

      _ ->
        nil
    end
  end

  defp maybe_dispatch(_text, nil), do: :ok

  defp maybe_dispatch(text, dispatcher_pid) do
    case InputAdapter.translate(text) do
      nil -> :ok
      event -> GenServer.cast(dispatcher_pid, {:dispatch, event})
    end
  end
end
