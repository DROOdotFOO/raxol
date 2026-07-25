defmodule Raxol.Gateway.Pipeline.TranscribeTest do
  use ExUnit.Case, async: true

  alias Raxol.Gateway.Pipeline.Transcribe

  @voice %{media: %{kind: :voice, ref: "file-123", mime: "audio/ogg", duration_s: 2}}

  defp attach_telemetry(events) do
    test_pid = self()
    handler_id = "transcribe-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "pass-through" do
    test "text events are unchanged" do
      assert Transcribe.run(%{text: "hi"}) == {:ok, %{text: "hi"}}
    end

    test "non-map and non-voice-media events are unchanged" do
      for event <- [:ping, {:tuple, 1}, %{}, %{media: %{kind: :photo, ref: "x"}}] do
        assert Transcribe.run(event) == {:ok, event}
      end
    end
  end

  describe "run/2 voice happy path" do
    test "fetch -> convert -> recognize plumbs each stage's output to the next" do
      test_pid = self()

      assert {:ok, %{text: "hello world", source: :voice}} =
               Transcribe.run(@voice,
                 fetch_fn: fn media ->
                   send(test_pid, {:fetched, media})
                   {:ok, "OGGBYTES"}
                 end,
                 convert_fn: fn bytes ->
                   send(test_pid, {:converted, bytes})
                   {:ok, "PCMBYTES"}
                 end,
                 recognize_fn: fn pcm ->
                   send(test_pid, {:recognized, pcm})
                   {:ok, " hello world "}
                 end
               )

      assert_received {:fetched, %{kind: :voice, ref: "file-123"}}
      assert_received {:converted, "OGGBYTES"}
      assert_received {:recognized, "PCMBYTES"}
    end

    test "emits done telemetry with sizes, never content" do
      attach_telemetry([[:raxol_gateway, :transcribe, :done]])

      assert {:ok, _event} =
               Transcribe.run(@voice,
                 fetch_fn: fn _ -> {:ok, "12345678"} end,
                 convert_fn: fn _ -> {:ok, "PCM0"} end,
                 recognize_fn: fn _ -> {:ok, "hey"} end
               )

      assert_received {:telemetry, [:raxol_gateway, :transcribe, :done], measurements, meta}
      assert measurements == %{audio_bytes: 8, transcript_chars: 3}
      assert meta == %{kind: :voice}
    end
  end

  describe "run/2 voice failure paths" do
    setup do
      attach_telemetry([[:raxol_gateway, :transcribe, :error]])
      :ok
    end

    test "a voice event without a :fetch_fn is dropped" do
      assert Transcribe.run(@voice, []) == :ignore
      assert_received {:telemetry, _, _, %{stage: :fetch, reason: :no_fetch_fn}}
    end

    test "a fetch error drops the event" do
      assert Transcribe.run(@voice, fetch_fn: fn _ -> {:error, :download_failed} end) ==
               :ignore

      assert_received {:telemetry, _, _, %{stage: :fetch, reason: :download_failed}}
    end

    test "oversized size_bytes metadata skips the fetch entirely" do
      assert Transcribe.run(
               %{media: %{kind: :voice, ref: "big", size_bytes: 100}},
               max_bytes: 99,
               fetch_fn: fn _ -> raise "must not fetch" end
             ) == :ignore

      assert_received {:telemetry, _, _, %{stage: :fetch, reason: :too_large}}
    end

    test "oversized fetched audio is dropped" do
      assert Transcribe.run(@voice,
               max_bytes: 4,
               fetch_fn: fn _ -> {:ok, "12345"} end
             ) == :ignore

      assert_received {:telemetry, _, _, %{stage: :fetch, reason: :too_large}}
    end

    test "a convert error drops the event" do
      assert Transcribe.run(@voice,
               fetch_fn: fn _ -> {:ok, "OGG1"} end,
               convert_fn: fn _ -> {:error, {:ffmpeg_exit, 1}} end
             ) == :ignore

      assert_received {:telemetry, _, _, %{stage: :convert, reason: {:ffmpeg_exit, 1}}}
    end

    test "empty converted PCM drops the event" do
      assert Transcribe.run(@voice,
               fetch_fn: fn _ -> {:ok, "OGG1"} end,
               convert_fn: fn _ -> {:ok, ""} end
             ) == :ignore

      assert_received {:telemetry, _, _, %{stage: :convert, reason: :empty_output}}
    end

    test "a recognize error drops the event" do
      assert Transcribe.run(@voice,
               fetch_fn: fn _ -> {:ok, "OGG1"} end,
               convert_fn: fn _ -> {:ok, "PCM1"} end,
               recognize_fn: fn _ -> {:error, :timeout} end
             ) == :ignore

      assert_received {:telemetry, _, _, %{stage: :recognize, reason: :timeout}}
    end

    test "an empty transcript drops the event" do
      assert Transcribe.run(@voice,
               fetch_fn: fn _ -> {:ok, "OGG1"} end,
               convert_fn: fn _ -> {:ok, "PCM1"} end,
               recognize_fn: fn _ -> {:ok, "  \n "} end
             ) == :ignore

      assert_received {:telemetry, _, _, %{stage: :recognize, reason: :empty_transcript}}
    end

    test "the default recognize_fn reports the Recognizer process missing" do
      # raxol_speech is a dev-time path dep here, so the module loads but its
      # Recognizer GenServer is never started in this suite.
      assert Transcribe.run(@voice,
               fetch_fn: fn _ -> {:ok, "OGG1"} end,
               convert_fn: fn _ -> {:ok, "PCM1"} end
             ) == :ignore

      assert_received {:telemetry, _, _, %{stage: :recognize, reason: :recognizer_not_running}}
    end

    test "oversized duration_s metadata skips the fetch entirely" do
      assert Transcribe.run(
               %{media: %{kind: :voice, ref: "long", duration_s: 11}},
               max_duration_s: 10,
               fetch_fn: fn _ -> raise "must not fetch" end
             ) == :ignore

      assert_received {:telemetry, _, _, %{stage: :fetch, reason: :too_long}}
    end

    test "PCM beyond the duration budget drops the event" do
      # No duration metadata, so only the decoded size can catch it:
      # max_duration_s: 1 allows (1 + 1) * 64_000 bytes of slack-included PCM.
      assert Transcribe.run(
               %{media: %{kind: :voice, ref: "lied-about-length"}},
               max_duration_s: 1,
               fetch_fn: fn _ -> {:ok, "OGG1"} end,
               convert_fn: fn _ -> {:ok, :binary.copy(<<0>>, 130_000)} end
             ) == :ignore

      assert_received {:telemetry, _, _, %{stage: :convert, reason: :pcm_too_large}}
    end

    test "a raising stage fn lands on the fail-open path with a content-free reason" do
      assert Transcribe.run(@voice, fetch_fn: fn _ -> raise "boom" end) == :ignore

      assert_received {:telemetry, _, _, %{stage: :fetch, reason: {:crashed, RuntimeError}}}
    end

    test "an exiting stage fn lands on the fail-open path" do
      assert Transcribe.run(@voice,
               fetch_fn: fn _ -> {:ok, "OGG1"} end,
               convert_fn: fn _ -> {:ok, "PCM1"} end,
               recognize_fn: fn _ -> exit(:recognizer_died) end
             ) == :ignore

      assert_received {:telemetry, _, _,
                       %{stage: :recognize, reason: {:crashed, {:exit, :recognizer_died}}}}
    end
  end

  describe "convert_with_ffmpeg/2" do
    setup do
      tmp_dir =
        Path.join(System.tmp_dir!(), "transcribe_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)
      %{tmp_dir: tmp_dir}
    end

    test "writes input to a temp file, converts, and cleans up", %{tmp_dir: tmp_dir} do
      ffmpeg = fake_ffmpeg!(tmp_dir)
      test_pid = self()

      cmd_fn = fn path, args ->
        input = Enum.at(args, Enum.find_index(args, &(&1 == "-i")) + 1)
        send(test_pid, {:cmd, path, args, input, File.read!(input)})
        {"PCMOUT", 0}
      end

      assert {:ok, "PCMOUT"} =
               Transcribe.convert_with_ffmpeg("OGGBYTES",
                 ffmpeg_path: ffmpeg,
                 cmd_fn: cmd_fn,
                 tmp_dir: tmp_dir
               )

      assert_received {:cmd, ^ffmpeg, args, input, "OGGBYTES"}
      assert Enum.take(args, 4) == ["-hide_banner", "-loglevel", "error", "-i"]

      assert args -- ["-hide_banner", "-loglevel", "error", "-i", input] ==
               ["-t", "300", "-f", "f32le", "-ac", "1", "-ar", "16000", "pipe:1"]

      refute File.exists?(input)
    end

    test "run/2 forwards ffmpeg options to the default converter", %{tmp_dir: tmp_dir} do
      ffmpeg = fake_ffmpeg!(tmp_dir)
      test_pid = self()

      cmd_fn = fn path, args ->
        send(test_pid, {:cmd, path, args})
        {"PCMOUT", 0}
      end

      assert {:ok, %{text: "from voice", source: :voice}} =
               Transcribe.run(@voice,
                 fetch_fn: fn _ -> {:ok, "OGGBYTES"} end,
                 recognize_fn: fn "PCMOUT" -> {:ok, "from voice"} end,
                 ffmpeg_path: ffmpeg,
                 cmd_fn: cmd_fn,
                 tmp_dir: tmp_dir,
                 max_duration_s: 42
               )

      assert_received {:cmd, ^ffmpeg, args}

      assert Enum.take(args, -9) == [
               "-t",
               "42",
               "-f",
               "f32le",
               "-ac",
               "1",
               "-ar",
               "16000",
               "pipe:1"
             ]
    end

    test "cleans up the temp file when ffmpeg fails", %{tmp_dir: tmp_dir} do
      ffmpeg = fake_ffmpeg!(tmp_dir)
      test_pid = self()

      cmd_fn = fn _path, args ->
        input = Enum.at(args, Enum.find_index(args, &(&1 == "-i")) + 1)
        send(test_pid, {:input, input})
        {"", 187}
      end

      assert {:error, {:ffmpeg_exit, 187}} =
               Transcribe.convert_with_ffmpeg("junk",
                 ffmpeg_path: ffmpeg,
                 cmd_fn: cmd_fn,
                 tmp_dir: tmp_dir
               )

      assert_received {:input, input}
      refute File.exists?(input)
    end

    test "rejects a binary not named ffmpeg", %{tmp_dir: tmp_dir} do
      other = Path.join(tmp_dir, "not_ffmpeg")
      File.write!(other, "")

      assert Transcribe.convert_with_ffmpeg("x",
               ffmpeg_path: other,
               cmd_fn: fn _, _ -> raise "no" end
             ) ==
               {:error, :ffmpeg_not_allowed}
    end

    test "rejects an ffmpeg path that does not exist", %{tmp_dir: tmp_dir} do
      assert Transcribe.convert_with_ffmpeg("x",
               ffmpeg_path: Path.join(tmp_dir, "ffmpeg"),
               cmd_fn: fn _, _ -> raise "no" end
             ) == {:error, :ffmpeg_not_allowed}
    end

    @tag :ffmpeg_live
    test "real ffmpeg converts generated audio to f32le mono 16k PCM", %{tmp_dir: tmp_dir} do
      ffmpeg = System.find_executable("ffmpeg") || flunk("ffmpeg not installed")

      ogg = Path.join(tmp_dir, "tone.ogg")

      {_out, 0} =
        System.cmd(ffmpeg, [
          "-hide_banner",
          "-loglevel",
          "error",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:duration=1",
          "-ac",
          "1",
          ogg
        ])

      assert {:ok, pcm} = Transcribe.convert_with_ffmpeg(File.read!(ogg), tmp_dir: tmp_dir)

      # 1s of f32le mono at 16kHz is 64_000 bytes, modulo codec padding.
      assert rem(byte_size(pcm), 4) == 0
      assert_in_delta byte_size(pcm), 64_000, 8_000
    end
  end

  # File.exists? must pass for the allowlist, but the injected :cmd_fn
  # means the fake is never executed. The setup's rm_rf cleans it up.
  defp fake_ffmpeg!(tmp_dir) do
    path = Path.join(tmp_dir, "ffmpeg")
    File.write!(path, "")
    path
  end
end
