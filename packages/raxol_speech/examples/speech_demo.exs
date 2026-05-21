#
# Live-test harness for the Raxol speech surface (TTS + STT).
#
# Runs locally on the dev machine -- no remote services required.
#
# Prerequisites
#   TTS:   macOS `say` (built-in) or Linux `espeak-ng` / `espeak`.
#   STT:   `sox` on $PATH (Homebrew: `brew install sox`).
#          Optional: bumblebee + nx + exla deps installed AND a usable
#          Whisper model. Without these, recording works but transcription
#          returns {:error, :bumblebee_not_available}.
#
# Run from the package directory:
#
#   cd packages/raxol_speech
#   mix run --no-halt examples/speech_demo.exs
#
# To skip the STT segment (no microphone or no `sox`):
#
#   SKIP_STT=1 mix run --no-halt examples/speech_demo.exs
#
# To extend record duration:
#
#   STT_DURATION_MS=5000 mix run --no-halt examples/speech_demo.exs
#

require Logger

defmodule SpeechDemo do
  alias Raxol.Speech.{Listener, Speaker}
  alias Raxol.Speech.TTS.{Noop, OsSay}

  @tts_phrase "Raxol speech demo. The quick brown fox jumps over the lazy dog."

  def run do
    backend = pick_tts_backend()
    Logger.info("Starting Speaker with backend #{inspect(backend)}.")
    start_supervised!(backend)
    start_supervised!({Speaker, tts_backend: backend})

    Logger.info("Speaking: #{inspect(@tts_phrase)}")
    Speaker.speak(@tts_phrase)

    # Give the speech command time to complete.
    Process.sleep(estimate_speak_duration_ms(@tts_phrase))

    if System.get_env("SKIP_STT") in [nil, "0", ""] do
      run_stt_segment()
    else
      Logger.info("SKIP_STT set, exiting after TTS.")
    end

    :ok
  end

  defp pick_tts_backend do
    case :os.type() do
      {:unix, _} -> OsSay
      _ -> Noop
    end
  end

  defp estimate_speak_duration_ms(text) do
    # ~160 wpm = ~480 ms per word + buffer.
    word_count = text |> String.split() |> length()
    word_count * 480 + 1_000
  end

  defp run_stt_segment do
    duration_ms = parse_duration()

    Logger.info("Starting Listener (record duration: #{duration_ms}ms).")
    start_supervised!(Raxol.Speech.Recognizer)
    start_supervised!({Listener, max_duration_ms: duration_ms})

    case Listener.start_recording() do
      :ok ->
        Logger.info("Recording for #{duration_ms}ms -- speak now...")
        Process.sleep(duration_ms)

        case Listener.stop_recording() do
          {:ok, text} ->
            Logger.info("Recognized: #{inspect(text)}")

          {:error, :no_audio} ->
            Logger.warning("No audio captured.")

          {:error, :bumblebee_not_available} ->
            Logger.info("Recording succeeded, but Bumblebee/Whisper isn't loaded -- transcription skipped.")

          {:error, reason} ->
            Logger.error("Recognition failed: #{inspect(reason)}")
        end

      {:error, :no_record_command} ->
        Logger.error("No record command found on PATH. Install sox: `brew install sox`.")

      {:error, reason} ->
        Logger.error("Listener.start_recording failed: #{inspect(reason)}")
    end
  end

  defp parse_duration do
    case System.get_env("STT_DURATION_MS") do
      nil -> 3_000
      str -> String.to_integer(str)
    end
  end

  defp start_supervised!(spec) do
    case Supervisor.start_child(SpeechDemo.Supervisor, spec_to_child(spec)) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "failed to start #{inspect(spec)}: #{inspect(reason)}"
    end
  end

  defp spec_to_child(mod) when is_atom(mod), do: %{id: mod, start: {mod, :start_link, [[]]}}

  defp spec_to_child({mod, opts}) when is_atom(mod) and is_list(opts) do
    %{id: mod, start: {mod, :start_link, [opts]}}
  end
end

{:ok, _sup} = Supervisor.start_link([], strategy: :one_for_one, name: SpeechDemo.Supervisor)

SpeechDemo.run()
