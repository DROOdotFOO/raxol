defmodule Raxol.Speech.TelemetryTest do
  use ExUnit.Case, async: false

  alias Raxol.Speech.{Speaker, TTS.Noop}

  setup do
    start_supervised!(Noop)
    start_supervised!({Speaker, tts_backend: Noop})
    Noop.clear()

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:raxol_speech, :tts, :speak, :start],
        [:raxol_speech, :tts, :speak, :stop],
        [:raxol_speech, :tts, :speak, :exception],
        [:raxol_speech, :tts, :stopped],
        [:raxol_speech, :tts, :interrupted]
      ])

    on_exit(fn -> :telemetry.detach(ref) end)

    :ok
  end

  describe "Speaker.speak emits a :tts.speak span" do
    test "fires :start and :stop with metadata" do
      Speaker.speak("hello")

      assert_receive {[:raxol_speech, :tts, :speak, :start], _ref, _,
                      %{source: :api, backend: Noop, byte_size: 5}}

      assert_receive {[:raxol_speech, :tts, :speak, :stop], _ref, %{duration: duration},
                      %{source: :api, backend: Noop, result: :ok}}

      assert is_integer(duration) and duration >= 0
    end
  end

  describe "Speaker.stop_speaking emits :tts.stopped" do
    test "fires with source :api" do
      Speaker.stop_speaking()
      assert_receive {[:raxol_speech, :tts, :stopped], _, _, %{source: :api}}
    end
  end

  describe "announcement-driven speech" do
    test "normal-priority announcement emits a :speak span with announcement source" do
      send(
        Speaker,
        {:announcement_added, make_ref(), %{message: "build complete", priority: :normal}}
      )

      assert_receive {[:raxol_speech, :tts, :speak, :start], _, _,
                      %{source: :announcement, priority: :normal}}

      assert_receive {[:raxol_speech, :tts, :speak, :stop], _, _, _}
    end

    test "high-priority announcement emits :interrupted before the :speak span" do
      send(
        Speaker,
        {:announcement_added, make_ref(), %{message: "build failed", priority: :high}}
      )

      assert_receive {[:raxol_speech, :tts, :interrupted], _, _,
                      %{priority: :high, backend: Noop}}

      assert_receive {[:raxol_speech, :tts, :speak, :start], _, _,
                      %{source: :announcement, priority: :high}}
    end
  end
end
