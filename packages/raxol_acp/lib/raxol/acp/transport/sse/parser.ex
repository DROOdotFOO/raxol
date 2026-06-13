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
          {:ok, value} when is_map(value) -> {:ok, value}
          _ -> {:error, :invalid_json}
        end
    end
  end

  defp extract_data_line("data: " <> rest), do: [rest]
  defp extract_data_line("data:" <> rest), do: [String.trim_leading(rest, " ")]
  defp extract_data_line(_), do: []
end
