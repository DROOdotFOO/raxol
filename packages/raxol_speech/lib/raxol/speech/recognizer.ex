defmodule Raxol.Speech.Recognizer do
  @moduledoc """
  Speech recognition via Bumblebee/Whisper.

  Wraps an `Nx.Serving` instance with a Whisper model for on-BEAM
  speech-to-text. Falls back gracefully when Bumblebee is not available.

  ## Options

    * `:model` - HuggingFace model ID (default: `"openai/whisper-tiny"`)
    * `:compiler` - Nx compiler (default: `EXLA` if available)
    * `:recognize_timeout_ms` - per-call transcription budget (default
      30_000). The FIRST call after boot also pays the XLA graph
      compilation, which can take minutes on CPU; give a cold deployment
      a generous budget or warm the serving up front.
  """

  use Raxol.Core.Behaviours.BaseManager

  @compile {:no_warn_undefined, [Bumblebee, Nx, Nx.Serving, EXLA]}

  @default_model "openai/whisper-tiny"
  @default_recognize_timeout_ms 30_000

  defstruct [:serving, :model_name, :recognize_timeout_ms]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Recognize speech from audio binary data.

  The binary must be raw PCM: 32-bit little-endian floats, one channel,
  at the model's sampling rate (16kHz for Whisper). Compressed audio
  (ogg/opus voice notes, mp3, wav) must be converted first, e.g.:

      ffmpeg -i voice.ogg -f f32le -ac 1 -ar 16000 pipe:1

  A binary that cannot be f32 PCM (empty, or not a multiple of 4 bytes)
  returns `{:error, :invalid_pcm}` without touching the model. Note the
  serving rejects whole WAV/AIFF/OGG files: container bytes are not
  samples.

  Transcription runs in a separate Task to avoid blocking the GenServer.
  """
  @spec recognize(binary()) :: {:ok, String.t()} | {:error, term()}
  def recognize(audio_data)
      when is_binary(audio_data) and
             (audio_data == <<>> or rem(byte_size(audio_data), 4) != 0) do
    {:error, :invalid_pcm}
  end

  def recognize(audio_data) when is_binary(audio_data) do
    case GenServer.call(__MODULE__, {:get_serving, audio_data}) do
      {:ok, serving, timeout_ms} ->
        task = Task.async(fn -> do_transcribe(serving, audio_data) end)

        case Task.yield(task, timeout_ms) || Task.shutdown(task) do
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

    {:ok,
     %__MODULE__{
       serving: serving,
       model_name: model_name,
       recognize_timeout_ms:
         Keyword.get(opts, :recognize_timeout_ms, @default_recognize_timeout_ms)
     }}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(
        {:get_serving, _audio_data},
        _from,
        %{serving: nil} = state
      ) do
    {:reply, {:error, :bumblebee_not_available}, state}
  end

  def handle_manager_call({:get_serving, _audio_data}, _from, state) do
    {:reply, {:ok, state.serving, state.recognize_timeout_ms}, state}
  end

  def handle_manager_call(:available?, _from, state) do
    {:reply, state.serving != nil, state}
  end

  # -- Private --

  defp do_transcribe(serving, audio_data) do
    meta = %{audio_bytes: byte_size(audio_data)}

    :telemetry.span([:raxol_speech, :recognize], meta, fn ->
      # Bumblebee's whisper serving takes a 1-dimensional tensor (or
      # {:file, path}); a `{:binary, _}` tuple is rejected outright, so
      # the raw f32 PCM is wrapped as a tensor here.
      result =
        try do
          output = Nx.Serving.run(serving, Nx.from_binary(audio_data, :f32))
          text = extract_text(output)
          {:ok, text}
        rescue
          e -> {:error, Exception.message(e)}
        end

      stop_meta =
        case result do
          {:ok, text} -> Map.merge(meta, %{success: true, text: text})
          {:error, reason} -> Map.merge(meta, %{success: false, error: reason})
        end

      {result, stop_meta}
    end)
  end

  defp bumblebee_available? do
    Code.ensure_loaded?(Bumblebee) and Code.ensure_loaded?(Nx.Serving)
  end

  defp load_whisper_serving(model_name, opts) do
    try do
      {:ok, model} = Bumblebee.load_model({:hf, model_name})
      {:ok, featurizer} = Bumblebee.load_featurizer({:hf, model_name})
      {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model_name})

      {:ok, generation_config} =
        Bumblebee.load_generation_config({:hf, model_name})

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

        Logger.warning(
          "Failed to load Whisper model #{model_name}: #{Exception.message(e)}"
        )

        nil
    end
  end

  defp detect_compiler do
    if Code.ensure_loaded?(EXLA), do: EXLA, else: nil
  end

  defp extract_text(%{chunks: [%{text: text} | _]}), do: String.trim(text)
  defp extract_text(%{results: [%{text: text} | _]}), do: String.trim(text)
  defp extract_text(_), do: ""
end
