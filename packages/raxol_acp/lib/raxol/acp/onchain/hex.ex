defmodule Raxol.ACP.Onchain.Hex do
  @moduledoc """
  Ethereum JSON-RPC hex codec shared by the on-chain wire paths
  (`Raxol.ACP.Onchain.RPC`, `Raxol.ACP.Wallet.SCA.Bundler`, the provider
  adapters). Zero deps beyond the standard library.

  DATA (byte strings: calldata, signatures, addresses) uses `encode/1`.
  QUANTITY (non-negative integers) uses `encode_quantity/1`. Both are
  lower-case on the wire; nodes parse QUANTITY case-insensitively.
  """

  @doc "Encode a byte string as 0x-prefixed lower-case hex (DATA)."
  @spec encode(binary()) :: String.t()
  def encode(bytes) when is_binary(bytes), do: "0x" <> Base.encode16(bytes, case: :lower)

  @doc "Encode a non-negative integer as a 0x-prefixed minimal hex QUANTITY."
  @spec encode_quantity(non_neg_integer()) :: String.t()
  def encode_quantity(n) when is_integer(n) and n >= 0,
    do: "0x" <> (n |> Integer.to_string(16) |> String.downcase())

  @doc """
  Decode a 0x-prefixed hex QUANTITY to an integer. `"0x"` decodes as 0.
  Returns `{:ok, int}` or `{:error, {:hex_decode, value, reason}}`.
  """
  @spec decode_quantity(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def decode_quantity("0x"), do: {:ok, 0}

  def decode_quantity("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {n, ""} -> {:ok, n}
      _ -> {:error, {:hex_decode, "0x" <> hex, :not_integer}}
    end
  end

  def decode_quantity(other), do: {:error, {:hex_decode, other, :missing_0x_prefix}}

  @doc "Decode a 0x-prefixed hex QUANTITY to a bare integer, raising on malformed input."
  @spec decode_quantity!(String.t()) :: non_neg_integer()
  def decode_quantity!("0x"), do: 0
  def decode_quantity!("0x" <> hex), do: String.to_integer(hex, 16)
end
