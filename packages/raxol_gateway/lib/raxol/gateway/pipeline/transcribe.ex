defmodule Raxol.Gateway.Pipeline.Transcribe do
  @moduledoc """
  Feed-loop stage that turns a voice media event into a `%{text: transcript}`
  event before it is routed.

  A platform adapter normalizes a voice note to
  `%{media: %{kind: :voice, ref: ref, ...}}` (e.g.
  `Raxol.Telegram.GatewayAdapter` for `message.voice` updates). This stage
  fetches the audio behind `ref`, converts it to raw PCM, transcribes it, and
  hands the transcript on as the ordinary `%{text: binary}` event every
  `Raxol.Gateway.Handler` already understands. Any non-voice event passes
  through untouched, so the stage composes unconditionally:

      with {:ok, route, event} <- MyAdapter.normalize_event(raw),
           {:ok, event} <- Transcribe.run(event, fetch_fn: fetch) do
        Raxol.Gateway.SessionRouter.route(router, route, event)
      end

  ## Why a feed-loop stage, not a Session concern

  A `Raxol.Gateway.Session` records the raw inbound event to its `:log`
  before the handler sees it, and it processes events one at a time. Running
  STT inside the session would log opaque media references instead of
  transcripts and block the per-chat mailbox for the whole recognition run.
  In the feed loop the logged event is the transcript, and only the feed
  callback (e.g. the poller's `:on_update`) waits.

  ## Options

    * `:fetch_fn` - `(media_map -> {:ok, binary} | {:error, term})`. Fetches
      the audio bytes behind the media `:ref`; platform-specific, so there is
      no default (a voice event without one is dropped). For Telegram:
      `fn media -> Raxol.Telegram.GatewayAdapter.fetch_media(conn, media) end`.
    * `:convert_fn` - `(binary -> {:ok, pcm} | {:error, term})`. Converts the
      fetched audio to raw f32le mono 16kHz PCM (what
      `Raxol.Speech.Recognizer.recognize/1` takes). Default:
      `convert_with_ffmpeg/2` with these options.
    * `:recognize_fn` - `(pcm -> {:ok, text} | {:error, term})`. Default:
      `Raxol.Speech.Recognizer.recognize/1` when the optional `raxol_speech`
      dependency is loaded and its Recognizer process is running.
    * `:max_bytes` - drop audio larger than this before converting (default
      20MB, the Bot API `getFile` ceiling). Checked against the media's
      `:size_bytes` metadata before fetching and against the fetched binary.
    * `:ffmpeg_path`, `:cmd_fn`, `:tmp_dir` - see `convert_with_ffmpeg/2`.

  ## Failure mode

  Fail-open per event: any stage failure (no `:fetch_fn`, fetch/convert
  errors, STT unavailable, empty transcript) drops that one voice event with
  `:ignore`, a `Logger.warning`, and `[:raxol_gateway, :transcribe, :error]`
  telemetry (metadata `%{stage, reason, kind}`). Text traffic is unaffected;
  a dropped voice note never takes the chat down. Successful runs emit
  `[:raxol_gateway, :transcribe, :done]` with the audio and transcript sizes.
  Neither audio bytes nor transcript text ever reach the logs.

  ## Latency

  The stage blocks its caller for the whole fetch + convert + recognize run.
  The first recognition after boot also pays the XLA graph compile (minutes
  on CPU); give `Raxol.Speech.Recognizer` a generous `:recognize_timeout_ms`
  via `Raxol.Speech.Supervisor`'s `:recognizer_opts` or warm the serving up
  front, otherwise every cold call times out, aborts the compile, and the
  next call starts it over.
  """

  @compile {:no_warn_undefined, [Raxol.Speech.Recognizer]}

  require Logger

  # The Bot API refuses getFile downloads above 20MB; other platforms get
  # the same ceiling as a sane default.
  @default_max_bytes 20 * 1024 * 1024
  @allowed_convert_binaries ~w(ffmpeg)
  @ffmpeg_output_args ~w(-f f32le -ac 1 -ar 16000 pipe:1)

  @type event :: term()
  @type media :: %{
          required(:kind) => atom(),
          required(:ref) => term(),
          optional(atom()) => term()
        }

  @doc """
  Transcribe a voice media event; pass any other event through unchanged.

  Returns `{:ok, %{text: transcript, source: :voice}}` for a transcribed
  voice event, `{:ok, event}` untouched for everything else, and `:ignore`
  when a voice event cannot be transcribed (logged, never raised).
  """
  @spec run(event(), keyword()) :: {:ok, event()} | :ignore
  def run(event, opts \\ [])

  def run(%{media: %{kind: :voice} = media}, opts) do
    with {:ok, bytes} <- fetch(media, opts),
         {:ok, pcm} <- convert(bytes, opts),
         {:ok, text} <- recognize(pcm, opts) do
      emit_done(byte_size(bytes), text)
      {:ok, %{text: text, source: :voice}}
    else
      {:error, stage, reason} -> drop(stage, reason)
    end
  end

  def run(event, _opts), do: {:ok, event}

  @doc """
  Default `:convert_fn`: decode any audio ffmpeg understands to raw f32le
  mono 16kHz PCM.

  `System.cmd/3` cannot feed stdin, so the input bytes go through a
  temporary file (deleted afterwards, success or not):

      ffmpeg -hide_banner -loglevel error -i <tmp> -f f32le -ac 1 -ar 16000 pipe:1

  ## Options

    * `:ffmpeg_path` - executable path (default `System.find_executable("ffmpeg")`).
      Only a binary named `ffmpeg` that exists on disk is accepted.
    * `:cmd_fn` - `(path, args -> {output_binary, exit_status})` runner
      override for tests (default `System.cmd/3`)
    * `:tmp_dir` - where the temporary input file goes (default
      `System.tmp_dir!()`)
  """
  @spec convert_with_ffmpeg(binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def convert_with_ffmpeg(bytes, opts \\ []) when is_binary(bytes) do
    case ffmpeg_path(opts) do
      {:ok, path} -> run_ffmpeg(path, bytes, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch(media, opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    with :ok <- check_declared_size(media, max_bytes),
         {:ok, fetch_fn} <- fetch_fn(opts) do
      validate_fetched(fetch_fn.(media), max_bytes)
    end
  end

  defp check_declared_size(%{size_bytes: size}, max_bytes)
       when is_integer(size) and size > max_bytes,
       do: {:error, :fetch, :too_large}

  defp check_declared_size(_media, _max_bytes), do: :ok

  defp fetch_fn(opts) do
    case Keyword.get(opts, :fetch_fn) do
      nil -> {:error, :fetch, :no_fetch_fn}
      fun -> {:ok, fun}
    end
  end

  defp validate_fetched({:ok, bytes}, max_bytes)
       when is_binary(bytes) and byte_size(bytes) <= max_bytes,
       do: {:ok, bytes}

  defp validate_fetched({:ok, bytes}, _max_bytes) when is_binary(bytes),
    do: {:error, :fetch, :too_large}

  defp validate_fetched({:ok, _other}, _max_bytes), do: {:error, :fetch, :invalid_fetch_result}
  defp validate_fetched({:error, reason}, _max_bytes), do: {:error, :fetch, reason}

  defp convert(bytes, opts) do
    convert_fn = Keyword.get(opts, :convert_fn, &convert_with_ffmpeg(&1, opts))

    case convert_fn.(bytes) do
      {:ok, pcm} when is_binary(pcm) and pcm != <<>> -> {:ok, pcm}
      {:ok, <<>>} -> {:error, :convert, :empty_output}
      {:ok, _other} -> {:error, :convert, :invalid_convert_result}
      {:error, reason} -> {:error, :convert, reason}
    end
  end

  defp recognize(pcm, opts) do
    recognize_fn = Keyword.get(opts, :recognize_fn, &default_recognize/1)

    case recognize_fn.(pcm) do
      {:ok, text} when is_binary(text) ->
        case String.trim(text) do
          "" -> {:error, :recognize, :empty_transcript}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _other} ->
        {:error, :recognize, :invalid_recognize_result}

      {:error, reason} ->
        {:error, :recognize, reason}
    end
  end

  defp default_recognize(pcm) do
    cond do
      not Code.ensure_loaded?(Raxol.Speech.Recognizer) -> {:error, :speech_not_available}
      is_nil(Process.whereis(Raxol.Speech.Recognizer)) -> {:error, :recognizer_not_running}
      true -> Raxol.Speech.Recognizer.recognize(pcm)
    end
  end

  defp ffmpeg_path(opts) do
    case Keyword.get(opts, :ffmpeg_path) || System.find_executable("ffmpeg") do
      nil ->
        {:error, :ffmpeg_not_found}

      path ->
        if Path.basename(path) in @allowed_convert_binaries and File.exists?(path) do
          {:ok, path}
        else
          {:error, :ffmpeg_not_allowed}
        end
    end
  end

  defp run_ffmpeg(path, bytes, opts) do
    cmd_fn = Keyword.get(opts, :cmd_fn, &System.cmd/2)
    tmp_dir = Keyword.get(opts, :tmp_dir, System.tmp_dir!())

    tmp =
      Path.join(tmp_dir, "raxol_transcribe_#{System.unique_integer([:positive])}.audio")

    with :ok <- File.write(tmp, bytes) do
      try do
        case cmd_fn.(path, ~w(-hide_banner -loglevel error -i) ++ [tmp] ++ @ffmpeg_output_args) do
          {pcm, 0} -> {:ok, pcm}
          {_out, status} -> {:error, {:ffmpeg_exit, status}}
        end
      after
        File.rm(tmp)
      end
    end
  end

  defp drop(stage, reason) do
    Logger.warning("gateway transcribe dropped a voice event at #{stage}: #{inspect(reason)}")

    :telemetry.execute(
      [:raxol_gateway, :transcribe, :error],
      %{count: 1},
      %{stage: stage, reason: reason, kind: :voice}
    )

    :ignore
  end

  defp emit_done(audio_bytes, text) do
    :telemetry.execute(
      [:raxol_gateway, :transcribe, :done],
      %{audio_bytes: audio_bytes, transcript_chars: String.length(text)},
      %{kind: :voice}
    )
  end
end
