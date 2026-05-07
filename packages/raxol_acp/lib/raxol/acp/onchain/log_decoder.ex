defmodule Raxol.ACP.Onchain.LogDecoder do
  @moduledoc """
  Decodes Ethereum event logs out of `eth_getTransactionReceipt`
  responses.

  ## Background

  An Ethereum event log has three pieces:

  - `topics` -- an array of 32-byte hex strings. `topics[0]` is the
    event signature hash (`keccak256(canonical_signature)`); subsequent
    topics are the **indexed** parameters in declaration order, each
    padded to 32 bytes.
  - `data` -- 0x-prefixed hex of the **non-indexed** parameters,
    encoded per the Solidity ABI head/tail rules.
  - `address` -- the contract that emitted the log.

  This module covers the topic side (event signature hash, decoding
  indexed primitives). Non-indexed parameter decoding is out of scope
  for v0.1 -- the only ACP event we need is `JobCreated`, whose first
  indexed parameter is the new `uint256 jobId`. Add an ABI decoder
  here if/when an event with non-indexed payload data matters.

  ## v0.1 use case

  `Raxol.ACP.ContractClient.Onchain.create_job/3` uses this module to
  pull the new `jobId` out of a `JobCreated` event in the transaction
  receipt. The exact event signature is configurable via
  `:create_job_event_signature` so the placeholder (`JobCreated(uint256)`)
  swaps cleanly when Virtuals' real ABI is vendored.

  ## Examples

      iex> Raxol.ACP.Onchain.LogDecoder.event_topic("Transfer(address,address,uint256)")
      "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

      iex> Raxol.ACP.Onchain.LogDecoder.decode_uint256("0x" <> String.duplicate("0", 62) <> "2a")
      42
  """

  @type log :: %{required(String.t()) => any()}

  # -- Topic computation --

  @doc """
  Compute the 0x-prefixed lowercase hex of `keccak256(canonical_signature)`.

  The canonical signature is the Solidity event declaration with
  parameter types only, no spaces, e.g. `"Transfer(address,address,uint256)"`.
  """
  @spec event_topic(String.t()) :: String.t()
  def event_topic(canonical_signature) when is_binary(canonical_signature) do
    "0x" <> Base.encode16(ExKeccak.hash_256(canonical_signature), case: :lower)
  end

  # -- Log lookup --

  @doc """
  Find the first log in `logs` whose `topics[0]` matches `event_topic`.

  Accepts either a precomputed topic hash (`"0x..."`) or a canonical
  event signature; the latter is hashed automatically.

  Returns `{:ok, log}` or `:error` (no matching log).
  """
  @spec find_event([log()], String.t()) :: {:ok, log()} | :error
  def find_event(logs, "0x" <> _ = topic) when is_list(logs) do
    do_find(logs, normalize(topic))
  end

  def find_event(logs, signature) when is_list(logs) and is_binary(signature) do
    find_event(logs, event_topic(signature))
  end

  defp do_find([], _topic), do: :error

  defp do_find([log | rest], topic) do
    case Map.get(log, "topics", []) do
      [first | _] ->
        if normalize(first) == topic, do: {:ok, log}, else: do_find(rest, topic)

      _ ->
        do_find(rest, topic)
    end
  end

  defp normalize("0x" <> hex), do: "0x" <> String.downcase(hex)
  defp normalize(other) when is_binary(other), do: String.downcase(other)

  # -- Indexed parameter decoders --

  @doc """
  Decode a 32-byte topic value (hex) as a `uint256`.

  Topics are always 32 bytes; the integer is right-aligned, padded
  with zeros on the left.
  """
  @spec decode_uint256(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def decode_uint256("0x" <> hex) when byte_size(hex) == 64 do
    case Integer.parse(hex, 16) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, {:bad_uint256, "0x" <> hex}}
    end
  end

  def decode_uint256(other), do: {:error, {:bad_uint256, other}}

  @doc """
  Decode a 32-byte topic value (hex) as an `address`.

  The address is the last 20 bytes of the 32-byte topic; the leading
  12 bytes must be zero.
  """
  @spec decode_address(String.t()) :: {:ok, String.t()} | {:error, term()}
  def decode_address("0x" <> hex) when byte_size(hex) == 64 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<padding::binary-size(12), addr::binary-size(20)>>} ->
        if padding == <<0::8*12>> do
          {:ok, "0x" <> Base.encode16(addr, case: :lower)}
        else
          {:error, {:bad_address_padding, "0x" <> hex}}
        end

      _ ->
        {:error, {:bad_address_hex, "0x" <> hex}}
    end
  end

  def decode_address(other), do: {:error, {:bad_address, other}}

  @doc """
  Decode a 32-byte topic value (hex) as `bytes32`. Returns the raw
  32-byte binary.
  """
  @spec decode_bytes32(String.t()) :: {:ok, binary()} | {:error, term()}
  def decode_bytes32("0x" <> hex) when byte_size(hex) == 64 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<bytes::binary-size(32)>>} -> {:ok, bytes}
      _ -> {:error, {:bad_bytes32_hex, "0x" <> hex}}
    end
  end

  def decode_bytes32(other), do: {:error, {:bad_bytes32, other}}

  # -- Convenience: extract first indexed uint256 --

  @doc """
  Find a log matching `event_signature_or_topic` and decode the
  parameter at `topic_index` (1-based; topic 0 is the event hash) as
  the given type.

  Returns `{:ok, value}` on success or `{:error, reason}`.

  This is the convenience used by `ContractClient.Onchain.create_job`
  to extract the new `jobId` from a `JobCreated` event without
  spelling out the find/decode steps every time.

      iex> log = %{"topics" => [
      ...>   "0x1234...",  # event hash
      ...>   "0x" <> String.duplicate("0", 62) <> "2a"
      ...> ]}
      iex> Raxol.ACP.Onchain.LogDecoder.extract(
      ...>   [log],
      ...>   "0x1234...",
      ...>   1,
      ...>   :uint256
      ...> )
      {:ok, 42}
  """
  @spec extract([log()], String.t(), pos_integer(), :uint256 | :address | :bytes32) ::
          {:ok, term()} | {:error, term()}
  def extract(logs, event, topic_index, type)
      when is_list(logs) and is_binary(event) and is_integer(topic_index) and topic_index > 0 do
    with {:ok, log} <- find_or_error(logs, event),
         topics <- Map.get(log, "topics", []),
         {:ok, raw} <- nth_topic(topics, topic_index) do
      decode_one(raw, type)
    end
  end

  defp find_or_error(logs, event) do
    case find_event(logs, event) do
      {:ok, log} -> {:ok, log}
      :error -> {:error, {:event_not_found, event}}
    end
  end

  defp nth_topic(topics, index) when length(topics) > index, do: {:ok, Enum.at(topics, index)}
  defp nth_topic(_topics, index), do: {:error, {:topic_out_of_range, index}}

  defp decode_one(raw, :uint256), do: decode_uint256(raw)
  defp decode_one(raw, :address), do: decode_address(raw)
  defp decode_one(raw, :bytes32), do: decode_bytes32(raw)
end
