defmodule Raxol.Agent.Journal.Chain do
  @moduledoc """
  The hash chain of a `chain: true` journal (schema_version 1.2.0).

  Every record of a chained journal carries two extra keys:

    * `"prev_hash"` -- the `"hash"` of the record before it; the first record
      (id 1) links to `genesis/0`, 64 zeros. One chain spans every segment: the
      first record of segment N links to the last record of segment N-1.
    * `"hash"` -- lowercase hex SHA-256 of the record's canonical JSON with the
      `"hash"` key removed (so it covers `"prev_hash"`, which is what chains it).

  ## Canonical JSON

  The canonical form of a decoded JSON value is: objects with keys sorted by
  byte order at every depth, arrays in order, no whitespace, strings and
  integers as `Jason` encodes them with `escape: :json`. It is defined over the
  DECODED record, not the bytes a writer happened to emit, so any JSON decoder
  can recompute it. Floats are refused at append (`{:error, {:float, path}}`):
  their text form is the one thing in JSON with no single canonical spelling,
  and money in a chained journal is a decimal string.

  A chained record line on disk is exactly the canonical JSON of the record,
  `"hash"` included. The reader checks that too, so a byte change that decodes
  to the same value (a hex-digit case flip inside a `\\u` escape, say) is still
  a break.

  The chain detects corruption, truncation and naive edits. It carries no
  key: anyone who can rewrite the journal directory can rewrite the chain.
  """

  @genesis String.duplicate("0", 64)

  @doc "The `prev_hash` of the first record of a chain: 64 zeros."
  @spec genesis() :: String.t()
  def genesis, do: @genesis

  @doc """
  Seal a stamped record onto the chain after `prev_hash`.

  `record` may hold anything `Jason` encodes (atoms, structs with an encoder);
  it is normalized through one encode/decode round trip first, so the hash is
  computed over exactly what a reader will decode. Returns the line to write
  (canonical JSON, no trailing newline) and the record's hash.
  """
  @spec seal(map(), String.t()) ::
          {:ok, iodata(), String.t()}
          | {:error, {:float, [String.t() | non_neg_integer()]} | {:unencodable, String.t()}}
  def seal(record, prev_hash) when is_map(record) and is_binary(prev_hash) do
    with {:ok, decoded} <- normalize(record),
         :ok <- reject_floats(decoded, []) do
      body = decoded |> Map.delete("hash") |> Map.put("prev_hash", prev_hash)
      hash = digest(body)
      {:ok, canonical(Map.put(body, "hash", hash)), hash}
    end
  end

  @doc """
  Check one decoded record against its predecessor's hash and the raw line it
  was decoded from. `:ok` only when the record links to `prev_hash`, its
  `"hash"` matches its content, and `raw` is its canonical encoding.
  """
  @spec check(map(), String.t(), binary()) :: :ok | :broken
  def check(%{"prev_hash" => prev_hash, "hash" => hash} = record, prev_hash, raw)
      when is_binary(hash) do
    if digest(Map.delete(record, "hash")) == hash and
         IO.iodata_to_binary(canonical(record)) == raw,
       do: :ok,
       else: :broken
  end

  def check(_record, _prev_hash, _raw), do: :broken

  @doc "Canonical JSON (see the moduledoc) of a decoded JSON value, as iodata."
  @spec canonical(term()) :: iodata()
  def canonical(map) when is_map(map) do
    members =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> [Jason.encode_to_iodata!(key), ?:, canonical(value)] end)

    [?{, Enum.intersperse(members, ?,), ?}]
  end

  def canonical(list) when is_list(list),
    do: [?[, Enum.intersperse(Enum.map(list, &canonical/1), ?,), ?]]

  def canonical(scalar), do: Jason.encode_to_iodata!(scalar)

  defp digest(body) do
    :sha256
    |> :crypto.hash(canonical(body))
    |> Base.encode16(case: :lower)
  end

  defp normalize(record) do
    case Jason.encode(record) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      {:error, e} -> {:error, {:unencodable, Exception.message(e)}}
    end
  rescue
    e in Protocol.UndefinedError -> {:error, {:unencodable, Exception.message(e)}}
  end

  defp reject_floats(value, path) when is_float(value), do: {:error, {:float, Enum.reverse(path)}}

  defp reject_floats(map, path) when is_map(map) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      case reject_floats(value, [key | path]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp reject_floats(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case reject_floats(value, [index | path]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp reject_floats(_scalar, _path), do: :ok
end
