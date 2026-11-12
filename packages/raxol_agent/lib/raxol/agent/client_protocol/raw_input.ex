defmodule Raxol.Agent.ClientProtocol.RawInput do
  @max_depth 4
  @max_bytes 4_096
  @max_opaque_bytes 200
  @cut "..."

  @moduledoc """
  A tool call's params as the `rawInput` an ACP client shows before it is
  asked to allow the call.

  `render/1` returns a JSON-encodable copy, bounded so that a call with huge
  or hostile arguments cannot flood the wire or the client's dialog:

    * maps and lists are followed #{@max_depth} levels deep; a deeper one
      is shown by `inspect/2`
    * the copy carries about #{@max_bytes} bytes of keys and values; once
      that is spent, what is left of a map or list is replaced by `"..."`
      and a string is cut short and ends in `...`
    * atoms become strings; a struct, a tuple, a binary that is not UTF-8
      and anything else JSON has no form for is shown by `inspect/2`, cut
      to #{@max_opaque_bytes} bytes

  Nothing is redacted: the client is shown what the action will be called
  with.
  """

  @doc "The bounded, JSON-encodable copy of `params`."
  @spec render(term()) :: term()
  def render(params) do
    {rendered, _left} = walk(params, @max_depth, @max_bytes)
    rendered
  end

  # Every clause spends at least one byte of `left`, so a walk ends.
  defp walk(value, _depth, left) when is_number(value) or is_boolean(value) or is_nil(value),
    do: {value, left - 8}

  defp walk(value, _depth, left) when is_atom(value), do: text(Atom.to_string(value), left)

  defp walk(value, _depth, left) when is_binary(value) do
    if String.valid?(value), do: text(value, left), else: opaque(value, left)
  end

  defp walk(value, depth, left) when is_list(value) and depth > 0,
    do: items(value, depth - 1, left - 2)

  defp walk(value, depth, left) when is_map(value) and not is_struct(value) and depth > 0,
    do: entries(:maps.next(:maps.iterator(value)), depth - 1, left - 2, %{})

  defp walk(value, _depth, left), do: opaque(value, left)

  defp items([], _depth, left), do: {[], left}
  defp items(_more, _depth, left) when left <= 0, do: {[@cut], left}

  defp items([head | tail], depth, left) when is_list(tail) do
    {head, left} = walk(head, depth, left)
    {tail, left} = items(tail, depth, left)
    {[head | tail], left}
  end

  defp items(improper, _depth, left), do: opaque(improper, left)

  defp entries(:none, _depth, left, acc), do: {acc, left}
  defp entries(_more, _depth, left, acc) when left <= 0, do: {Map.put(acc, @cut, @cut), left}

  defp entries({key, value, next}, depth, left, acc) do
    {key, left} = key |> key() |> text(left)
    {value, left} = walk(value, depth, left)
    entries(:maps.next(next), depth, left, Map.put(acc, key, value))
  end

  defp key(key) when is_binary(key), do: if(String.valid?(key), do: key, else: inspect(key))
  defp key(key) when is_atom(key), do: Atom.to_string(key)
  defp key(key), do: inspect(key, limit: 5, printable_limit: @max_opaque_bytes)

  defp text(text, left), do: {clip(text, max(left, 0)), left - byte_size(text) - 2}

  defp opaque(value, left) do
    value
    |> inspect(limit: 20, printable_limit: @max_opaque_bytes)
    |> clip(@max_opaque_bytes)
    |> text(left)
  end

  # Cut on a character boundary at or below `max` bytes.
  defp clip(text, max) when byte_size(text) <= max, do: text

  defp clip(text, max) do
    case :unicode.characters_to_binary(binary_part(text, 0, max)) do
      {:incomplete, whole, _partial} -> whole <> @cut
      {:error, whole, _invalid} -> whole <> @cut
      whole -> whole <> @cut
    end
  end
end
