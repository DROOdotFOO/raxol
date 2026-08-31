defmodule Raxol.Agent.Actions.Anchor do
  @moduledoc """
  Line anchors: the shared address vocabulary between `read_file` and
  `edit_file`.

  An anchor is `"LINE:HASH"` — a 1-based line number and the first six hex
  digits of the SHA-256 of that line's exact bytes. `read_file` prefixes
  every line it returns with one:

      12:a3f1c2|defp handle(x) do

  and `edit_file` addresses a range by copying those prefixes back:

      from: "12:a3f1c2", to: "14:9b0d31"

  The model never retypes the text it wants to replace, and the hash proves
  it is pointing at the bytes it read. A file that changed underneath fails
  the hash check and the edit is refused rather than applied to content the
  model never saw.

  ## What an anchor pair verifies

  Both endpoints of the range, exactly. Lines strictly between them are not
  hashed: an anchor the model can use is one it can reproduce from what it
  read, and it cannot hash a range itself. Endpoint drift catches the
  realistic case (the file moved or changed around the edit); a change
  confined to the interior of an addressed range does not.

  ## Line splitting

  `split/1` and `join/2` round-trip exactly, including whether the file
  ended with a newline, so an edit cannot silently add or drop a trailing
  one.
  """

  @hash_length 6
  @separator "|"

  @type anchor :: {pos_integer(), String.t()}

  @doc """
  Split content into its lines and whether it ended with a newline.

  The trailing newline is carried separately rather than as an empty final
  line, so line numbers match what an editor shows.
  """
  @spec split(String.t()) :: {[String.t()], boolean()}
  def split(""), do: {[], false}

  def split(content) do
    if String.ends_with?(content, "\n") do
      body = binary_part(content, 0, byte_size(content) - 1)
      {String.split(body, "\n"), true}
    else
      {String.split(content, "\n"), false}
    end
  end

  @doc "Inverse of `split/1`."
  @spec join([String.t()], boolean()) :: String.t()
  def join([], _trailing_newline?), do: ""
  def join(lines, true), do: Enum.join(lines, "\n") <> "\n"
  def join(lines, false), do: Enum.join(lines, "\n")

  @doc """
  How many characters an anchor hash occupies.

  Fixed, so a caller sizing a rendered line can count it instead of hashing
  the line a second time just to measure the result.
  """
  @spec hash_length() :: pos_integer()
  def hash_length, do: @hash_length

  @doc "The anchor hash of a single line's exact bytes."
  @spec hash(String.t()) :: String.t()
  def hash(line) do
    :sha256
    |> :crypto.hash(line)
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_length)
  end

  @doc """
  Render lines with their anchor prefixes, numbering from `first_line`.

  `first_line` is the 1-based number of the first line in `lines`, so a
  windowed read stays addressable at its real offsets.
  """
  @spec render([String.t()], pos_integer()) :: String.t()
  def render(lines, first_line) do
    lines
    |> Enum.with_index(first_line)
    |> Enum.map_join("\n", fn {line, number} ->
      "#{number}:#{hash(line)}#{@separator}#{line}"
    end)
  end

  @doc """
  Parse a `"LINE:HASH"` anchor.

  Returns `{:error, :malformed_anchor}` for anything else: a bad anchor is
  refused rather than guessed at, since guessing means editing a line the
  model did not name.
  """
  @spec parse(term()) :: {:ok, anchor()} | {:error, :malformed_anchor}
  def parse(value) when is_binary(value) do
    with [number, hash] <- String.split(value, ":", parts: 2),
         {line, ""} when line > 0 <- Integer.parse(number),
         true <- valid_hash?(hash) do
      {:ok, {line, hash}}
    else
      _ -> {:error, :malformed_anchor}
    end
  end

  def parse(_value), do: {:error, :malformed_anchor}

  defp valid_hash?(hash) do
    byte_size(hash) == @hash_length and
      String.match?(hash, ~r/\A[0-9a-f]+\z/)
  end

  @doc """
  Check that `anchor` still names the line it claims, within `lines`.

  Returns `{:error, {:anchor_out_of_range, line, count}}` when the line does
  not exist, and `{:error, {:anchor_mismatch, line, expected, actual}}` when
  it exists but holds different bytes.
  """
  @spec verify([String.t()], anchor()) ::
          :ok
          | {:error,
             {:anchor_out_of_range, pos_integer(), non_neg_integer()}
             | {:anchor_mismatch, pos_integer(), String.t(), String.t()}}
  def verify(lines, {line, expected}) do
    case Enum.at(lines, line - 1) do
      nil ->
        {:error, {:anchor_out_of_range, line, length(lines)}}

      content ->
        case hash(content) do
          ^expected -> :ok
          actual -> {:error, {:anchor_mismatch, line, expected, actual}}
        end
    end
  end
end
