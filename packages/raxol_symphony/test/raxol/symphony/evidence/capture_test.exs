defmodule Raxol.Symphony.Evidence.CaptureTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.Evidence.Capture

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "evidence_capture_#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)

    %{workspace: workspace}
  end

  defp read_cast(path) do
    [header_line | frame_lines] =
      path
      |> File.read!()
      |> String.trim_trailing("\n")
      |> String.split("\n")

    %{
      header: Jason.decode!(header_line),
      frames: Enum.map(frame_lines, &Jason.decode!/1)
    }
  end

  describe "path_for/2" do
    test "uses attempt suffix when given an integer" do
      assert Capture.path_for("/ws", 0) == "/ws/.raxol_symphony/run-0.cast"
      assert Capture.path_for("/ws", 3) == "/ws/.raxol_symphony/run-3.cast"
    end

    test "falls back to a unique suffix for nil attempt" do
      a = Capture.path_for("/ws", nil)
      b = Capture.path_for("/ws", nil)
      assert a != b
    end
  end

  describe "format_event/1" do
    test "text_delta has no label and includes the message" do
      assert Capture.format_event(%{event: :text_delta, message: "hello"}) == "hello\r\n"
    end

    test "tool_use is prefixed with [tool]" do
      assert Capture.format_event(%{event: :tool_use, message: "linear_graphql"}) ==
               "[tool] linear_graphql\r\n"
    end

    test "turn_completed surfaces total tokens when usage is present" do
      result =
        Capture.format_event(%{
          event: :turn_completed,
          usage: %{input_tokens: 1, output_tokens: 2, total_tokens: 42}
        })

      assert result == "[turn complete] tokens=42\r\n"
    end

    test "turn_completed without usage falls back to message or empty body" do
      assert Capture.format_event(%{event: :turn_completed, message: "done"}) ==
               "[turn complete] done\r\n"
    end

    test "unknown event uses the event-name as label and stringifies payload" do
      result = Capture.format_event(%{event: :something, payload: %{a: 1}})
      assert result =~ "[something]"
      assert result =~ "a:"
    end

    test "very long messages are truncated" do
      long_message = String.duplicate("x", 20_000)
      result = Capture.format_event(%{event: :text_delta, message: long_message})
      assert byte_size(result) <= 16_400
      assert String.ends_with?(result, "...[truncated]")
    end
  end

  describe "GenServer flow" do
    test "writes a valid asciicast v2 header on init", %{workspace: workspace} do
      path = Capture.path_for(workspace, 0)
      {:ok, pid} = Capture.start_link(path: path, width: 132, height: 50, title: "MT-1")
      :ok = Capture.stop(pid)

      cast = read_cast(path)
      assert cast.header["version"] == 2
      assert cast.header["width"] == 132
      assert cast.header["height"] == 50
      assert cast.header["title"] == "MT-1"
      assert is_integer(cast.header["timestamp"])
      assert cast.frames == []
    end

    test "appends a frame per event with monotonically non-decreasing timestamps", %{
      workspace: workspace
    } do
      path = Capture.path_for(workspace, 1)
      {:ok, pid} = Capture.start_link(path: path)

      Capture.record(pid, %{event: :session_started, message: "session abc"})
      Capture.record(pid, %{event: :text_delta, message: "hello"})
      Capture.record(pid, %{event: :turn_completed, usage: %{total_tokens: 7}})

      :ok = Capture.stop(pid)

      cast = read_cast(path)
      assert length(cast.frames) == 3

      times = Enum.map(cast.frames, &Enum.at(&1, 0))
      assert times == Enum.sort(times)

      texts = Enum.map(cast.frames, &Enum.at(&1, 2))
      assert Enum.any?(texts, &(&1 =~ "session abc"))
      assert Enum.any?(texts, &(&1 == "hello\r\n"))
      assert Enum.any?(texts, &(&1 == "[turn complete] tokens=7\r\n"))
    end

    test "creates the .raxol_symphony directory if missing", %{workspace: workspace} do
      path = Capture.path_for(workspace, 0)
      refute File.dir?(Path.dirname(path))

      {:ok, pid} = Capture.start_link(path: path)
      :ok = Capture.stop(pid)

      assert File.regular?(path)
    end

    test "no-ops on record/stop with nil pid" do
      assert Capture.record(nil, %{event: :text_delta, message: "x"}) == :ok
      assert Capture.stop(nil) == :ok
    end

    test "fails soft when path can't be opened (parent is a regular file)", %{
      workspace: workspace
    } do
      blocking = Path.join(workspace, "blocker")
      File.write!(blocking, "not a dir")
      bad_path = Path.join(blocking, "run.cast")

      {:ok, pid} = Capture.start_link(path: bad_path)
      assert :ok = Capture.record(pid, %{event: :text_delta, message: "x"})
      :ok = Capture.stop(pid)

      refute File.exists?(bad_path)
    end
  end
end
