defmodule Raxol.ACP.Transport.SSE.Parser do
  @moduledoc """
  Pure SSE wire-format parser used by `Raxol.ACP.Transport.SSE`.

  Extracted into its own module so tests can hit it directly without
  spinning up a stream. No state -- callers buffer their own partials
  between `split_frames/1` calls.
  """

  @doc """
  Split a chunk of SSE bytes into complete frames + a remainder.

  Frames are separated by `\\n\\n`. The trailing fragment (if any) is
  returned as the second element so the caller can prepend it to the
  next chunk.

      iex> Raxol.ACP.Transport.SSE.Parser.split_frames("data: 1\\n\\ndata: 2\\n\\n")
      {["data: 1", "data: 2"], ""}

      iex> Raxol.ACP.Transport.SSE.Parser.split_frames("data: a\\n\\ndata: b")
      {["data: a"], "data: b"}
  """
  @spec split_frames(binary()) :: {[binary()], binary()}
  def split_frames(text) when is_binary(text) do
    parts = String.split(text, "\n\n")

    case parts do
      [] -> {[], ""}
      [partial] -> {[], partial}
      list -> {Enum.drop(list, -1), List.last(list)}
    end
  end

  @doc """
  Parse a single SSE frame's data field into a JSON map.

  - `data:` lines (with or without leading space) are concatenated.
  - `event:` / `id:` / other field lines are ignored.
  - The accumulated `data` is parsed as JSON; the value must be an
    object.
  """
  @spec parse_frame(binary()) :: {:ok, map()} | {:error, :no_data | :invalid_json}
  def parse_frame(frame) when is_binary(frame) do
    data =
      frame
      |> String.split("\n")
      |> Enum.flat_map(&extract_data_line/1)
      |> Enum.join("\n")

    case data do
      "" ->
        {:error, :no_data}

      json ->
        case Jason.decode(json) do
          {:ok, value} when is_map(value) -> {:ok, normalize(value)}
          _ -> {:error, :invalid_json}
        end
    end
  end

  defp extract_data_line("data: " <> rest), do: [rest]
  defp extract_data_line("data:" <> rest), do: [String.trim_leading(rest, " ")]
  defp extract_data_line(_), do: []

  # Normalize the wire shape of an ACP SSE entry into the shape the Agent +
  # SolverAgent consume. The Virtuals server sends system events as
  # `%{"kind" => "system", "event" => %{"type" => "job.created", "provider" => ...,
  # "onChainJobId" => ...}}`, but our dispatch matches `"event" => "job.created"`
  # (a string) and reads top-level `jobId`/`provider`. So for system entries we hoist
  # the nested event map's fields to the top level and replace `event` with its type
  # string. Message entries already carry top-level `content`/`contentType`/`from`.
  # Both get `jobId` lifted from `onChainJobId`. This is the single boundary where the
  # wire shape meets our code (the gate drives the provider in-process and never hits
  # this path, which is why the mismatch went unseen until a real marketplace job).
  defp normalize(%{"kind" => "system", "event" => %{"type" => type} = ev} = entry) do
    entry
    |> Map.merge(ev)
    |> Map.put("event", type)
    |> Map.put("jobId", job_id(entry, ev))
  end

  defp normalize(%{} = entry) do
    Map.put(entry, "jobId", job_id(entry, entry["event"]))
  end

  defp job_id(entry, ev) do
    entry["jobId"] || entry["job_id"] || entry["onChainJobId"] ||
      map_get(ev, "onChainJobId") || map_get(ev, "jobId")
  end

  defp map_get(%{} = m, k), do: m[k]
  defp map_get(_, _), do: nil
end
