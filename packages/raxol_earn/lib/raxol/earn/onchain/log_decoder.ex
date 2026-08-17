defmodule Raxol.Earn.Onchain.LogDecoder do
  @moduledoc """
  Decodes Ethereum event logs out of `eth_getTransactionReceipt` responses.

  ## Background

  An Ethereum event log has three pieces:

  - `topics` -- an array of 32-byte hex strings. `topics[0]` is the event
    signature hash (`keccak256(canonical_signature)`); subsequent topics are the
    **indexed** parameters in declaration order, each padded to 32 bytes.
  - `data` -- 0x-prefixed hex of the **non-indexed** parameters, encoded per the
    Solidity ABI head/tail rules.
  - `address` -- the contract that emitted the log.

  This module covers the topic side (event signature hash, decoding indexed
  primitives). Non-indexed parameter decoding is out of scope -- the only ACP
  event a caller needs today is `JobCreated`, whose new `uint256 jobId` is an
  indexed parameter. Add an ABI `data` decoder here if an event with a
  non-indexed payload matters.

  ## Use case

  `Raxol.Earn.JobIdResolver.Receipt` uses this module to pull the new `jobId` out
  of a `JobCreated` event in a `createJob` transaction receipt. The exact event
  signature is not hard-coded here -- the resolver passes it in, so the
  placeholder signature swaps cleanly once the deployed `AgenticCommerceV3` ABI
  is confirmed against the Sepolia dry-run.

  ## Examples

      iex> Raxol.Earn.Onchain.LogDecoder.event_topic("Transfer(address,address,uint256)")
      "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

      iex> Raxol.Earn.Onchain.LogDecoder.decode_uint256("0x" <> String.duplicate("0", 62) <> "2a")
      {:ok, 42}
  """

  @type log :: %{required(String.t()) => any()}

  @typedoc """
  Extra constraints a log must satisfy, beyond its `topics[0]`.

  - `:emitter` -- the contract address the log must have been emitted by.
  - `:topics` -- expected values for indexed parameters, keyed by 1-based topic
    index. Each value is a 32-byte topic or a 20-byte address (left-padded to a
    topic here).

  An unset key constrains nothing. A log that does not CARRY a constrained key
  never matches -- a log with no `address` cannot prove which contract emitted
  it, so it cannot satisfy an `:emitter` constraint.
  """
  @type match_opts :: [
          {:emitter, String.t() | nil}
          | {:topics, %{optional(pos_integer()) => String.t()}}
        ]

  # -- Topic computation --

  @doc """
  Compute the 0x-prefixed lowercase hex of `keccak256(canonical_signature)`.

  The canonical signature is the Solidity event declaration with parameter types
  only, no spaces, e.g. `"Transfer(address,address,uint256)"`. Note this is the
  full 32-byte hash, unlike `Raxol.Earn.ABI`'s function selector which truncates
  to the first 4 bytes -- an event topic needs the whole hash.
  """
  @spec event_topic(String.t()) :: String.t()
  def event_topic(canonical_signature) when is_binary(canonical_signature) do
    "0x" <> Base.encode16(ExKeccak.hash_256(canonical_signature), case: :lower)
  end

  # -- Log lookup --

  @doc """
  Find the first log in `logs` whose `topics[0]` matches `event` and which
  satisfies every constraint in `opts`.

  Accepts either a precomputed topic hash (`"0x..."`) or a canonical event
  signature; the latter is hashed automatically.

  A signature match alone is not identity: one receipt can hold many logs of the
  same event from many senders (an ERC-4337 bundle receipt holds every
  co-bundled UserOp's logs). Pass `:emitter` / `:topics` to pin the log down to
  the one this caller caused.

  Returns `{:ok, log}` or `:error` (no matching log). Raises `ArgumentError` on
  a malformed expected topic value, since a mis-specified constraint that
  silently matched nothing would read exactly like an absent event.
  """
  @spec find_event([log()], String.t(), match_opts()) :: {:ok, log()} | :error
  def find_event(logs, event, opts \\ [])

  def find_event(logs, "0x" <> _ = topic, opts) when is_list(logs) and is_list(opts) do
    do_find(logs, normalize(topic), constraints(opts))
  end

  def find_event(logs, signature, opts)
      when is_list(logs) and is_binary(signature) and is_list(opts) do
    find_event(logs, event_topic(signature), opts)
  end

  defp constraints(opts) do
    %{
      emitter: normalize_emitter(Keyword.get(opts, :emitter)),
      topics:
        opts
        |> Keyword.get(:topics, %{})
        |> Map.new(fn {index, value} -> {index, expected_topic(index, value)} end)
    }
  end

  defp normalize_emitter(nil), do: nil
  defp normalize_emitter(address) when is_binary(address), do: normalize(address)

  defp expected_topic(_index, "0x" <> hex = value) when byte_size(hex) == 64, do: normalize(value)

  defp expected_topic(_index, "0x" <> hex) when byte_size(hex) == 40,
    do: "0x" <> String.duplicate("0", 24) <> String.downcase(hex)

  defp expected_topic(index, value) do
    raise ArgumentError,
          "expected topic #{index} must be a 32-byte topic or a 20-byte address, " <>
            "got: #{inspect(value)}"
  end

  defp do_find([], _topic, _constraints), do: :error

  defp do_find([log | rest], topic, constraints) do
    if matches?(log, topic, constraints) do
      {:ok, log}
    else
      do_find(rest, topic, constraints)
    end
  end

  defp matches?(log, topic, constraints) do
    signature_matches?(log, topic) and emitted_by?(log, constraints.emitter) and
      indexed_match?(log, constraints.topics)
  end

  defp signature_matches?(log, topic) do
    case Map.get(log, "topics", []) do
      [first | _] when is_binary(first) -> normalize(first) == topic
      _ -> false
    end
  end

  defp emitted_by?(_log, nil), do: true

  defp emitted_by?(log, emitter) do
    case Map.get(log, "address") do
      address when is_binary(address) -> normalize(address) == emitter
      _ -> false
    end
  end

  defp indexed_match?(_log, expected) when map_size(expected) == 0, do: true

  defp indexed_match?(log, expected) do
    topics = Map.get(log, "topics", [])
    Enum.all?(expected, fn {index, value} -> topic_matches?(topics, index, value) end)
  end

  defp topic_matches?(topics, index, expected) do
    case Enum.at(topics, index) do
      raw when is_binary(raw) -> normalize(raw) == expected
      _ -> false
    end
  end

  defp normalize("0x" <> hex), do: "0x" <> String.downcase(hex)
  defp normalize(other) when is_binary(other), do: String.downcase(other)

  # -- Indexed parameter decoders --

  @doc """
  Decode a 32-byte topic value (hex) as a `uint256`.

  Topics are always 32 bytes; the integer is right-aligned, padded with zeros on
  the left.
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
  Decode a 32-byte topic value (hex) as an `address` (last 20 bytes; the leading
  12 bytes must be zero).
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

  # -- Convenience: extract an indexed parameter --

  @doc """
  Find a log matching `event` (canonical signature or topic hash) under `opts`
  and decode the parameter at `topic_index` (1-based; topic 0 is the event hash)
  as `type`.

  Returns `{:ok, value}` or `{:error, reason}`. Used by
  `Raxol.Earn.JobIdResolver.Receipt` to extract the new `jobId` from a
  `JobCreated` event without spelling out the find/decode steps every time.
  """
  @spec extract([log()], String.t(), pos_integer(), :uint256 | :address, match_opts()) ::
          {:ok, term()} | {:error, term()}
  def extract(logs, event, topic_index, type, opts \\ [])
      when is_list(logs) and is_binary(event) and is_integer(topic_index) and topic_index > 0 and
             is_list(opts) do
    with {:ok, log} <- find_or_error(logs, event, opts),
         topics <- Map.get(log, "topics", []),
         {:ok, raw} <- nth_topic(topics, topic_index) do
      decode_one(raw, type)
    end
  end

  defp find_or_error(logs, event, opts) do
    case find_event(logs, event, opts) do
      {:ok, log} -> {:ok, log}
      :error -> {:error, {:event_not_found, event}}
    end
  end

  defp nth_topic(topics, index) when length(topics) > index, do: {:ok, Enum.at(topics, index)}
  defp nth_topic(_topics, index), do: {:error, {:topic_out_of_range, index}}

  defp decode_one(raw, :uint256), do: decode_uint256(raw)
  defp decode_one(raw, :address), do: decode_address(raw)
end
