defmodule Raxol.Payments.Wallets.Env do
  @moduledoc """
  Wallet that loads a private key from an environment variable.

  The key must be hex-encoded (with or without 0x prefix). The address
  is derived from the public key at module load time.

  ## Configuration

      # Set the env var
      export RAXOL_WALLET_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

      # Use in agent config
      wallet = Raxol.Payments.Wallets.Env

  ## Custom Env Var

      # Override at compile time
      defmodule MyWallet do
        use Raxol.Payments.Wallets.Env, env_var: "MY_WALLET_KEY"
      end
  """

  @behaviour Raxol.Payments.Wallet

  @default_env_var "RAXOL_WALLET_KEY"
  @default_chain_id 8453

  defmacro __using__(opts) do
    env_var = Keyword.get(opts, :env_var, @default_env_var)
    chain = Keyword.get(opts, :chain_id, @default_chain_id)

    quote do
      @behaviour Raxol.Payments.Wallet

      @impl true
      def address do
        Raxol.Payments.Wallets.Env.address(unquote(env_var))
      end

      @impl true
      def chain_id, do: unquote(chain)

      @impl true
      def sign_message(message) do
        Raxol.Payments.Wallets.Env.sign_message(message, unquote(env_var))
      end

      @impl true
      def sign_typed_data(domain, types, message) do
        Raxol.Payments.Wallets.Env.sign_typed_data(domain, types, message, unquote(env_var))
      end

      @impl true
      def sign_hash(digest) do
        Raxol.Payments.Wallets.Env.sign_hash(digest, unquote(env_var))
      end
    end
  end

  @impl true
  def address, do: address(@default_env_var)

  @impl true
  def chain_id, do: @default_chain_id

  @impl true
  def sign_message(message), do: sign_message(message, @default_env_var)

  @impl true
  def sign_typed_data(domain, types, message) do
    sign_typed_data(domain, types, message, @default_env_var)
  end

  @impl true
  def sign_hash(digest), do: sign_hash(digest, @default_env_var)

  @doc false
  @spec address(String.t()) :: String.t()
  def address(env_var) do
    with {:ok, privkey} <- load_key(env_var),
         {:ok, pubkey} <- ExSecp256k1.create_public_key(privkey) do
      derive_address(pubkey)
    else
      {:error, reason} -> raise "Failed to derive address: #{inspect(reason)}"
    end
  end

  @doc false
  @spec sign_message(binary(), String.t()) :: {:ok, binary()} | {:error, term()}
  def sign_message(message, env_var) do
    with {:ok, privkey} <- load_key(env_var) do
      hash = ExKeccak.hash_256(message)

      case ExSecp256k1.sign(hash, privkey) do
        {:ok, {r, s, v}} ->
          {:ok, <<r::binary-size(32), s::binary-size(32), v::8>>}

        {:error, reason} ->
          {:error, {:sign_failed, reason}}
      end
    end
  end

  @doc false
  @spec sign_typed_data(map(), map(), map(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def sign_typed_data(domain, types, message, env_var) do
    with {:ok, privkey} <- load_key(env_var),
         {:ok, hash} <- Raxol.Payments.EIP712.hash(domain, types, message) do
      case ExSecp256k1.sign(hash, privkey) do
        {:ok, {r, s, v}} ->
          {:ok, <<r::binary-size(32), s::binary-size(32), v::8>>}

        {:error, reason} ->
          {:error, {:sign_failed, reason}}
      end
    end
  end

  @doc false
  @spec sign_hash(<<_::256>>, String.t()) :: {:ok, binary()} | {:error, term()}
  def sign_hash(<<digest::binary-size(32)>>, env_var) do
    with {:ok, privkey} <- load_key(env_var) do
      case ExSecp256k1.sign(digest, privkey) do
        {:ok, {r, s, v}} ->
          {:ok, <<r::binary-size(32), s::binary-size(32), v::8>>}

        {:error, reason} ->
          {:error, {:sign_failed, reason}}
      end
    end
  end

  # -- Private --

  defp load_key(env_var) do
    case System.get_env(env_var) do
      nil ->
        {:error, {:env_not_set, env_var}}

      hex_key ->
        hex_key
        |> String.trim_leading("0x")
        |> Base.decode16(case: :mixed)
        |> case do
          {:ok, key} when byte_size(key) == 32 -> {:ok, key}
          {:ok, key} -> {:error, {:invalid_key_length, byte_size(key)}}
          :error -> {:error, :invalid_hex}
        end
    end
  end

  defp derive_address(pubkey) do
    # Drop the 04 prefix byte (uncompressed public key marker)
    <<_prefix::8, key_bytes::binary>> = pubkey
    <<_first_12::binary-size(12), address_bytes::binary-size(20)>> = ExKeccak.hash_256(key_bytes)
    "0x" <> Base.encode16(address_bytes, case: :lower)
  end
end
