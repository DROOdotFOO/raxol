defmodule Raxol.Speech.Recognizer do
  @moduledoc """
  Speech recognition via Bumblebee/Whisper.

  Wraps an `Nx.Serving` instance with a Whisper model for on-BEAM
  speech-to-text. Falls back gracefully when Bumblebee is not available.

  ## Options

    * `:model` - HuggingFace model ID (default: `"openai/whisper-tiny"`)
    * `:compiler` - Nx compiler (default: `EXLA` if available)
  """

  use Raxol.Core.Behaviours.BaseManager

  @compile {:no_warn_undefined, [Bumblebee, Nx.Serving, EXLA]}

  @default_model "openai/whisper-tiny"

  defstruct [:serving, :model_name]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Recognize speech from audio binary data.

  Accepts raw WAV/PCM audio data. Returns the transcribed text.
  Transcription runs in a separate Task to avoid blocking the GenServer.
  """
  @spec recognize(binary()) :: {:ok, String.t()} | {:error, term()}
  def recognize(audio_data) when is_binary(audio_data) do
    case GenServer.call(__MODULE__, {:get_serving, audio_data}) do
      {:ok, serving} ->
        task = Task.async(fn -> do_transcribe(serving, audio_data) end)

        case Task.yield(task, 30_000) || Task.shutdown(task) do
          {:ok, result} -> result
          nil -> {:error, :timeout}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc "Returns whether the recognizer has a loaded model."
  @spec available?() :: boolean()
  def available? do
    GenServer.call(__MODULE__, :available?)
  end

  # -- GenServer --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    model_name = Keyword.get(opts, :model, @default_model)

    serving =
      if bumblebee_available?() do
        load_whisper_serving(model_name, opts)
      else
        nil
      end

    {:ok, %__MODULE__{serving: serving, model_name: model_name}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:get_serving, _audio_data}, _from, %{serving: nil} = state) do
    {:reply, {:error, :bumblebee_not_available}, state}
  end

  def handle_manager_call({:get_serving, _audio_data}, _from, state) do
    {:reply, {:ok, state.serving}, state}
  end

  def handle_manager_call(:available?, _from, state) do
    {:reply, state.serving != nil, state}
  end

  # -- Private --

  defp do_transcribe(serving, audio_data) do
    start = System.monotonic_time(:millisecond)

    result =
      try do
        output = Nx.Serving.run(serving, {:binary, audio_data})
        text = extract_text(output)
        {:ok, text}
      rescue
        e -> {:error, Exception.message(e)}
      end

    duration = System.monotonic_time(:millisecond) - start
    emit_telemetry(result, duration)
    result
  end

  defp bumblebee_available? do
    Code.ensure_loaded?(Bumblebee) and Code.ensure_loaded?(Nx.Serving)
  end

  defp load_whisper_serving(model_name, opts) do
    try do
      {:ok, model} = Bumblebee.load_model({:hf, model_name})
      {:ok, featurizer} = Bumblebee.load_featurizer({:hf, model_name})
      {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_name})
      {:ok, generation_config} = Bumblebee.load_generation_config({:hf, model_name})

      compiler = Keyword.get(opts, :compiler, detect_compiler())

      defn_options =
        if compiler do
          [compiler: compiler]
        else
          []
        end

      Bumblebee.Audio.speech_to_text_whisper(
        model,
        featurizer,
        tokenizer,
        generation_config,
        defn_options: defn_options,
        chunk_num_seconds: 30
      )
    rescue
      e ->
        require Logger
        Logger.warning("Failed to load Whisper model #{model_name}: #{Exception.message(e)}")
        nil
    end
  end

  defp detect_compiler do
    if Code.ensure_loaded?(EXLA), do: EXLA, else: nil
  end

  defp extract_text(%{chunks: [%{text: text} | _]}), do: String.trim(text)
  defp extract_text(%{results: [%{text: text} | _]}), do: String.trim(text)
  defp extract_text(_), do: ""

  defp emit_telemetry(result, duration_ms) do
    if Code.ensure_loaded?(:telemetry) do
      text =
        case result do
          {:ok, t} -> t
          _ -> ""
        end

      :telemetry.execute(
        [:raxol, :speech, :recognized],
        %{duration_ms: duration_ms},
        %{text: text, success: match?({:ok, _}, result)}
      )
    end
  end
end
