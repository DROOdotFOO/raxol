defmodule Raxol.Speech.RecognizerTest do
  use ExUnit.Case

  alias Raxol.Speech.Recognizer

  # Without a model. Loading one fetches openai/whisper-tiny (~160 MB) from
  # huggingface.co whenever Bumblebee's cache lacks it, which in CI is every
  # run, and a failed fetch is logged and leaves no model, so these tests
  # would take a different path depending on the network and the cache. The
  # :stt_live test below starts its own recognizer with the model.
  setup do
    start_supervised!({Recognizer, load_model: false})
    :ok
  end

  describe "recognize/1" do
    test "returns an error tuple for invalid audio input" do
      # Whether Bumblebee is available or not, fake data should error
      assert {:error, _reason} = Recognizer.recognize("fake audio data")
    end

    test "rejects binaries that cannot be f32 PCM without touching the model" do
      assert Recognizer.recognize(<<>>) == {:error, :invalid_pcm}
      assert Recognizer.recognize(<<1, 2, 3>>) == {:error, :invalid_pcm}
      assert Recognizer.recognize("fake audio data") == {:error, :invalid_pcm}
    end
  end

  describe "available?/0" do
    test "is false without a loaded model, and recognize/1 then refuses valid PCM" do
      refute Recognizer.available?()
      assert Recognizer.recognize(<<0.0::float-32-little>>) == {:error, :bumblebee_not_available}
    end
  end

  describe "real transcription" do
    # Requires the Whisper model (cached or downloadable), EXLA, and
    # ffmpeg on PATH. The first inference also compiles the XLA graph,
    # which takes minutes on CPU - hence the generous budgets.
    @tag :stt_live
    @tag timeout: 2_400_000
    test "transcribes an ogg voice note after ffmpeg f32le extraction" do
      stop_supervised!(Recognizer)
      start_supervised!({Recognizer, [recognize_timeout_ms: 2_100_000]})

      fixture =
        Path.expand(Path.join([__DIR__, "..", "..", "fixtures", "hello.ogg"]))

      {pcm, 0} =
        System.cmd("ffmpeg", [
          "-hide_banner",
          "-loglevel",
          "error",
          "-i",
          fixture,
          "-f",
          "f32le",
          "-ac",
          "1",
          "-ar",
          "16000",
          "pipe:1"
        ])

      assert rem(byte_size(pcm), 4) == 0

      assert {:ok, text} = Recognizer.recognize(pcm)
      assert String.downcase(text) =~ "hello"
    end
  end
end
