# Generic, content-free player for a recorded OMP JSON-lines transcript
# (`scripts/omp_fixtures/capture.exs` format), run as a real OS process.
#
#   elixir gateway_transcript_player.exs TRANSCRIPT MODE [ignored args...]
#
# It walks the transcript in order. A run of consecutive `in` events reads that
# many lines from stdin and matches each one, id aside, against a recorded
# request of the run not yet matched; a line that matches none exits 97. An
# `out` event prints the recorded line, its `id` rewritten to the id the
# matching live request carried. `exit` waits for stdin EOF and exits with the
# recorded status.
#
# MODE: `play`; `exit-after:N:STATUS` (exit with STATUS right after matching
# request N, answering nothing more); `never-answer` (print the first recorded
# line, the ready line, then read stdin to EOF and answer nothing).

defmodule GatewayTranscriptPlayer do
  def main([transcript, mode | _ignored]) do
    [_header | lines] = transcript |> File.read!() |> String.split("\n", trim: true)
    events = Enum.map(lines, &JSON.decode!/1)

    case mode do
      "play" -> play(events, :infinity)
      "never-answer" -> never_answer(events)
      "exit-after:" <> spec -> play(events, parse_exit_after(spec))
    end
  end

  defp parse_exit_after(spec) do
    [n, status] = String.split(spec, ":")
    {String.to_integer(n), String.to_integer(status)}
  end

  defp never_answer([%{"out" => ready} | _rest]) do
    emit(ready)
    drain()
    System.halt(0)
  end

  defp play(events, exit_after), do: play(events, %{}, 0, exit_after)

  defp play([], _ids, _seen, _exit_after), do: System.halt(0)

  defp play([%{"in" => _} | _] = events, ids, seen, exit_after) do
    {run, rest} = Enum.split_while(events, &Map.has_key?(&1, "in"))
    {ids, seen} = match_run(Enum.map(run, & &1["in"]), ids, seen, exit_after)
    play(rest, ids, seen, exit_after)
  end

  defp play([%{"out" => line} | rest], ids, seen, exit_after) do
    emit(relabel(line, ids))
    play(rest, ids, seen, exit_after)
  end

  defp play([%{"exit" => status} | _rest], _ids, _seen, _exit_after) do
    drain()
    System.halt(status)
  end

  defp match_run([], ids, seen, _exit_after), do: {ids, seen}

  defp match_run(recorded, ids, seen, exit_after) do
    live = IO.read(:stdio, :line)
    if live == :eof, do: mismatch("stdin closed with #{length(recorded)} request(s) unmatched")
    live = String.trim_trailing(live, "\n")

    case Enum.find_index(recorded, &same_request?(&1, live)) do
      nil ->
        mismatch("request #{seen + 1} matches no recorded request")

      index ->
        {matched, recorded} = List.pop_at(recorded, index)
        ids = Map.put(ids, request_id(matched), request_id(live))
        seen = seen + 1
        maybe_exit(seen, exit_after)
        match_run(recorded, ids, seen, exit_after)
    end
  end

  defp maybe_exit(seen, {seen, status}), do: System.halt(status)
  defp maybe_exit(_seen, _exit_after), do: :ok

  defp same_request?(recorded, live), do: without_id(recorded) == without_id(live)

  defp without_id(line) do
    case JSON.decode(line) do
      {:ok, %{} = request} -> Map.delete(request, "id")
      _ -> line
    end
  end

  defp request_id(line) do
    case JSON.decode(line) do
      {:ok, %{"id" => id}} -> id
      _ -> nil
    end
  end

  defp relabel(line, ids) do
    case JSON.decode(line) do
      {:ok, %{"id" => id} = response} when is_map_key(ids, id) ->
        JSON.encode!(%{response | "id" => Map.fetch!(ids, id)})

      _ ->
        line
    end
  end

  defp drain do
    case IO.read(:stdio, :line) do
      :eof -> :ok
      _line -> drain()
    end
  end

  # The reader (the port) may already be gone, e.g. once a test has its
  # answer; there is nobody left to play to.
  defp emit(line) do
    IO.write([line, ?\n])
  catch
    :error, _closed -> System.halt(0)
  end

  defp mismatch(message) do
    IO.write(:stderr, "transcript player: #{message}\n")
    System.halt(97)
  end
end

GatewayTranscriptPlayer.main(System.argv())
