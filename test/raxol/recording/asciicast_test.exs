defmodule Raxol.Recording.AsciicastTest do
  use ExUnit.Case, async: true

  alias Raxol.Recording.{Asciicast, Session}

  describe "encode/1" do
    test "encodes empty session" do
      session = %Session{
        width: 80,
        height: 24,
        started_at: DateTime.from_unix!(1_700_000_000),
        events: []
      }

      result = Asciicast.encode(session)
      [header_line | _] = String.split(result, "\n")
      header = Jason.decode!(header_line)

      assert header["version"] == 2
      assert header["width"] == 80
      assert header["height"] == 24
      assert header["timestamp"] == 1_700_000_000
    end

    test "encodes session with events" do
      session = %Session{
        width: 80,
        height: 24,
        started_at: DateTime.from_unix!(1_700_000_000),
        events: [
          {0, :output, "hello"},
          {500_000, :output, " world"}
        ]
      }

      result = Asciicast.encode(session)
      lines = String.trim(result) |> String.split("\n")

      assert length(lines) == 3

      event1 = Jason.decode!(Enum.at(lines, 1))
      assert [+0.0, "o", "hello"] = event1

      event2 = Jason.decode!(Enum.at(lines, 2))
      assert [0.5, "o", " world"] = event2
    end

    test "includes title when present" do
      session = %Session{
        width: 80,
        height: 24,
        started_at: DateTime.from_unix!(1_700_000_000),
        title: "My Demo",
        events: []
      }

      result = Asciicast.encode(session)
      header = result |> String.split("\n") |> hd() |> Jason.decode!()
      assert header["title"] == "My Demo"
    end

    test "includes env when present" do
      session = %Session{
        width: 80,
        height: 24,
        started_at: DateTime.from_unix!(1_700_000_000),
        env: %{"TERM" => "xterm-256color"},
        events: []
      }

      result = Asciicast.encode(session)
      header = result |> String.split("\n") |> hd() |> Jason.decode!()
      assert header["env"]["TERM"] == "xterm-256color"
    end
  end

  describe "decode/1" do
    test "decodes encoded session (roundtrip)" do
      original = %Session{
        width: 120,
        height: 40,
        started_at: DateTime.from_unix!(1_700_000_000),
        title: "Roundtrip",
        env: %{"TERM" => "screen"},
        events: [
          {0, :output, "line 1\r\n"},
          {1_000_000, :output, "line 2\r\n"},
          {2_500_000, :output, "done"}
        ]
      }

      encoded = Asciicast.encode(original)
      decoded = Asciicast.decode(encoded)

      assert decoded.width == 120
      assert decoded.height == 40
      assert decoded.title == "Roundtrip"
      assert decoded.env["TERM"] == "screen"
      assert length(decoded.events) == 3

      # Check event data
      texts = Enum.map(decoded.events, fn {_t, _type, data} -> data end)
      assert texts == ["line 1\r\n", "line 2\r\n", "done"]

      # Check timestamps (microsecond precision may round)
      times = Enum.map(decoded.events, fn {t, _, _} -> t end)
      assert Enum.at(times, 0) == 0
      assert Enum.at(times, 1) == 1_000_000
      assert Enum.at(times, 2) == 2_500_000
    end

    test "handles ANSI escape codes in output" do
      session = %Session{
        width: 80,
        height: 24,
        started_at: DateTime.from_unix!(1_700_000_000),
        events: [
          {0, :output, "\e[31mred text\e[0m"},
          {100_000, :output, "\e[H\e[2J"}
        ]
      }

      encoded = Asciicast.encode(session)
      decoded = Asciicast.decode(encoded)

      [{_, _, data1}, {_, _, data2}] = decoded.events
      assert data1 == "\e[31mred text\e[0m"
      assert data2 == "\e[H\e[2J"
    end
  end

  describe "write!/2 and read!/1" do
    @tag :tmp_dir
    test "writes and reads .cast files", %{tmp_dir: dir} do
      path = Path.join(dir, "test.cast")

      session = %Session{
        width: 80,
        height: 24,
        started_at: DateTime.from_unix!(1_700_000_000),
        title: "File Test",
        events: [
          {0, :output, "hello"},
          {1_000_000, :output, "world"}
        ]
      }

      Asciicast.write!(session, path)
      assert File.exists?(path)

      loaded = Asciicast.read!(path)
      assert loaded.width == 80
      assert loaded.title == "File Test"
      assert length(loaded.events) == 2
    end
  end

  describe "torn-tail-tolerant reader" do
    defp sample_session(event_count) do
      events =
        for i <- 0..(event_count - 1) do
          {i * 100_000, :output, "event-#{i}\r\n"}
        end

      %Session{
        width: 80,
        height: 24,
        started_at: DateTime.from_unix!(1_700_000_000),
        title: "Torn Test",
        events: events
      }
    end

    @tag :tmp_dir
    test "recovers K-1 events when the final line is truncated mid-write", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "torn.cast")
      k = 6
      Asciicast.write!(sample_session(k), path)

      # Chop the file at a byte offset that lands inside the final event line.
      content = File.read!(path)
      lines = String.split(content, "\n", trim: true)
      assert length(lines) == k + 1

      # Keep everything up to and including the newline after the second-to-last
      # event, then add a partial fragment of the final event line (no newline).
      last_line = List.last(lines)
      keep = Enum.slice(lines, 0..(k - 1)) |> Enum.join("\n")
      fragment = String.slice(last_line, 0, div(String.length(last_line), 2))
      File.write!(path, keep <> "\n" <> fragment)

      session = Asciicast.read!(path)
      assert length(session.events) == k - 1

      texts = Enum.map(session.events, fn {_t, _type, data} -> data end)
      assert texts == for(i <- 0..(k - 2), do: "event-#{i}\r\n")
    end

    @tag :tmp_dir
    test "recovers all K events when truncation leaves the last line intact", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "intact.cast")
      k = 4
      Asciicast.write!(sample_session(k), path)

      # Drop only the trailing newline; every event line is complete.
      content = File.read!(path)
      File.write!(path, String.trim_trailing(content, "\n"))

      session = Asciicast.read!(path)
      assert length(session.events) == k
    end

    @tag :tmp_dir
    test "returns so-far events on an interior malformed line without raising",
         %{tmp_dir: dir} do
      path = Path.join(dir, "interior.cast")
      Asciicast.write!(sample_session(4), path)

      [header | events] = String.split(File.read!(path), "\n", trim: true)
      [e0, _bad, e2, e3] = events

      corrupted =
        Enum.join([header, e0, "not json at all", e2, e3], "\n") <> "\n"

      File.write!(path, corrupted)

      session = Asciicast.read!(path)
      # Stops at the malformed line -> only the first event survives.
      assert length(session.events) == 1
      assert [{_, :output, "event-0\r\n"}] = session.events
    end

    @tag :tmp_dir
    test "read/1 returns {:error, _} on an empty/garbage file instead of raising",
         %{tmp_dir: dir} do
      path = Path.join(dir, "empty.cast")
      File.write!(path, "")
      assert {:error, _} = Asciicast.read(path)

      garbage = Path.join(dir, "garbage.cast")
      File.write!(garbage, "this is not json\n")
      assert {:error, _} = Asciicast.read(garbage)
    end
  end

  describe "append!/2" do
    @tag :tmp_dir
    test "appends events without rewriting the header; reads back in order", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "append.cast")

      initial = %Session{
        width: 80,
        height: 24,
        started_at: DateTime.from_unix!(1_700_000_000),
        title: "Append Test",
        events: [
          {0, :output, "first"},
          {1_000_000, :output, "second"}
        ]
      }

      Asciicast.write!(initial, path)

      # Reopen and append two more events (relative timestamps preserved).
      Asciicast.append!(
        [{2_000_000, :output, "third"}, {3_500_000, :output, "fourth"}],
        path
      )

      # Exactly one header line survives.
      lines = File.read!(path) |> String.split("\n", trim: true)
      header = Jason.decode!(hd(lines))
      assert header["version"] == 2
      assert header["title"] == "Append Test"
      assert Enum.count(lines, &String.contains?(&1, "\"version\"")) == 1

      session = Asciicast.read!(path)
      texts = Enum.map(session.events, fn {_t, _type, data} -> data end)
      assert texts == ["first", "second", "third", "fourth"]

      times = Enum.map(session.events, fn {t, _, _} -> t end)
      assert times == [0, 1_000_000, 2_000_000, 3_500_000]
    end

    @tag :tmp_dir
    test "accepts a Session and appends its events", %{tmp_dir: dir} do
      path = Path.join(dir, "append_session.cast")

      Asciicast.write!(
        %Session{
          width: 80,
          height: 24,
          started_at: DateTime.from_unix!(1_700_000_000),
          events: [{0, :output, "a"}]
        },
        path
      )

      more = %Session{
        width: 80,
        height: 24,
        started_at: DateTime.from_unix!(1_700_000_000),
        events: [{500_000, :output, "b"}]
      }

      Asciicast.append!(more, path)

      session = Asciicast.read!(path)
      assert Enum.map(session.events, fn {_t, _, d} -> d end) == ["a", "b"]
    end

    @tag :tmp_dir
    test "raises when appending to a file with no valid header", %{tmp_dir: dir} do
      path = Path.join(dir, "noheader.cast")
      File.write!(path, "garbage\n")

      assert_raise ArgumentError, fn ->
        Asciicast.append!([{0, :output, "x"}], path)
      end
    end

    @tag :tmp_dir
    test "appending an empty event list is a byte-for-byte no-op", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "noop.cast")

      Asciicast.write!(
        %Session{
          width: 80,
          height: 24,
          started_at: DateTime.from_unix!(1_700_000_000),
          events: [{0, :output, "a"}]
        },
        path
      )

      before = File.read!(path)
      assert :ok = Asciicast.append!([], path)
      assert File.read!(path) == before
    end

    @tag :tmp_dir
    test "an empty append neither validates nor touches the file (no-op even on a non-cast)",
         %{tmp_dir: dir} do
      path = Path.join(dir, "garbage_noop.cast")
      File.write!(path, "not a cast\n")

      # No header validation, no trailing-newline fixup: the file is untouched.
      assert :ok = Asciicast.append!([], path)
      assert File.read!(path) == "not a cast\n"
    end
  end

  describe "append! trailing-newline handling (O(1))" do
    @tag :tmp_dir
    test "many sequential appends preserve order without introducing blank lines",
         %{tmp_dir: dir} do
      path = Path.join(dir, "many.cast")

      Asciicast.write!(
        %Session{
          width: 80,
          height: 24,
          started_at: DateTime.from_unix!(1_700_000_000),
          events: []
        },
        path
      )

      for i <- 0..49 do
        Asciicast.append!([{i * 1000, :output, "e#{i}"}], path)
      end

      session = Asciicast.read!(path)
      assert length(session.events) == 50

      assert Enum.map(session.events, fn {_t, _, d} -> d end) ==
               for(i <- 0..49, do: "e#{i}")

      # The O(1) newline check must never double-insert a separator.
      refute File.read!(path) =~ "\n\n"
    end

    @tag :tmp_dir
    test "inserts exactly one separator when the file does not end in a newline",
         %{tmp_dir: dir} do
      path = Path.join(dir, "nonewline.cast")

      # Header written with no trailing newline; the last-byte check must notice.
      header = ~s({"version":2,"width":80,"height":24,"timestamp":1700000000})
      File.write!(path, header)

      Asciicast.append!([{0, :output, "x"}], path)

      session = Asciicast.read!(path)
      assert Enum.map(session.events, fn {_t, _, d} -> d end) == ["x"]
      refute File.read!(path) =~ "\n\n"
    end

    @tag :tmp_dir
    test "adds no separator when the file already ends in a newline", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "withnewline.cast")

      Asciicast.write!(
        %Session{
          width: 80,
          height: 24,
          started_at: DateTime.from_unix!(1_700_000_000),
          events: [{0, :output, "first"}]
        },
        path
      )

      # write!/2 terminates the last event line with "\n".
      assert String.ends_with?(File.read!(path), "\n")

      Asciicast.append!([{1_000_000, :output, "second"}], path)

      session = Asciicast.read!(path)

      assert Enum.map(session.events, fn {_t, _, d} -> d end) == [
               "first",
               "second"
             ]

      refute File.read!(path) =~ "\n\n"
    end
  end

  describe "torn-tail vs flushed-corrupt distinction" do
    import ExUnit.CaptureLog

    defp session_lines(path) do
      [header | events] = String.split(File.read!(path), "\n", trim: true)
      {header, events}
    end

    @tag :tmp_dir
    test "a newline-terminated but unparseable final line warns (committed corruption)",
         %{tmp_dir: dir} do
      path = Path.join(dir, "flushed_corrupt.cast")
      Asciicast.write!(sample_session(3), path)

      {header, [e0, e1, _e2]} = session_lines(path)
      # Replace the final event line with garbage but keep the trailing newline:
      # the line was fully flushed, so this is real corruption.
      File.write!(
        path,
        Enum.join([header, e0, e1, "garbage-final"], "\n") <> "\n"
      )

      log =
        capture_log(fn ->
          session = Asciicast.read!(path)
          assert length(session.events) == 2
        end)

      assert log =~ "malformed event line"
    end

    @tag :tmp_dir
    test "a final line with no trailing newline recovers silently (torn mid-write)",
         %{tmp_dir: dir} do
      path = Path.join(dir, "torn_silent.cast")
      Asciicast.write!(sample_session(3), path)

      {header, [e0, e1, _e2]} = session_lines(path)

      # Final line is a torn fragment with NO trailing newline: killed mid-write.
      File.write!(path, Enum.join([header, e0, e1, "garbage-fragmen"], "\n"))

      log =
        capture_log(fn ->
          session = Asciicast.read!(path)
          assert length(session.events) == 2
        end)

      refute log =~ "malformed event line"
    end
  end

  describe "read/1 error surfacing" do
    @tag :tmp_dir
    test "a structurally-invalid header surfaces distinctly from a garbage/truncated file",
         %{tmp_dir: dir} do
      bad_ts = Path.join(dir, "bad_ts.cast")

      File.write!(
        bad_ts,
        ~s({"version":2,"width":80,"height":24,"timestamp":"not-a-number"}) <>
          "\n"
      )

      # Bad timestamp shape: a distinct ArgumentError, not a masked read failure.
      assert {:error, %ArgumentError{} = err} = Asciicast.read(bad_ts)
      assert Exception.message(err) =~ "timestamp"

      # Garbage/empty header: a JSON decode error, clearly a different failure.
      garbage = Path.join(dir, "garbage_header.cast")
      File.write!(garbage, "this is not json\n")
      assert {:error, %Jason.DecodeError{}} = Asciicast.read(garbage)
    end

    test "decode/1 raises ArgumentError on a bad-timestamp header" do
      content =
        ~s({"version":2,"width":80,"height":24,"timestamp":[1,2,3]}) <> "\n"

      assert_raise ArgumentError, ~r/timestamp/, fn ->
        Asciicast.decode(content)
      end
    end
  end

  describe "single-writer contract documentation" do
    test "append!/2 and the module document the single-writer contract" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, docs} =
        Code.fetch_docs(Asciicast)

      assert moduledoc =~ "single writer"

      append_doc =
        Enum.find_value(docs, fn
          {{:function, :append!, 2}, _, _, %{"en" => doc}, _} -> doc
          _ -> nil
        end)

      assert append_doc =~ "Single-writer"
    end
  end
end
