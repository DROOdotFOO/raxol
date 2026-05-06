defmodule Raxol.Payments.Wallets.Op do
  @moduledoc """
  Wallet that loads a private key from 1Password via the `op` CLI.

  The key is fetched once on first use and cached in a GenServer's state.
  No plaintext key ever touches disk.

  ## Configuration

      # Start the wallet process
      {:ok, pid} = Raxol.Payments.Wallets.Op.start_link(
        op_ref: "op://Employee/RaxolAgentKey/credential",
        chain_id: 8453
      )

      # Use as wallet module (via pid)
      Raxol.Payments.Wallets.Op.address(pid)
      Raxol.Payments.Wallets.Op.sign_message(pid, message)
  """

  use GenServer

  @default_chain_id 8453

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec address(GenServer.server()) :: String.t()
  def address(server) do
    GenServer.call(server, :address)
  end

  @spec chain_id(GenServer.server()) :: pos_integer()
  def chain_id(server) do
    GenServer.call(server, :chain_id)
  end

  @spec sign_message(GenServer.server(), binary()) ::
          {:ok, binary()} | {:error, term()}
  def sign_message(server, message) do
    GenServer.call(server, {:sign_message, message})
  end

  @spec sign_typed_data(GenServer.server(), map(), map(), map()) ::
          {:ok, binary()} | {:error, term()}
  def sign_typed_data(server, domain, types, message) do
    GenServer.call(server, {:sign_typed_data, domain, types, message})
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    op_ref = Keyword.fetch!(opts, :op_ref)
    chain = Keyword.get(opts, :chain_id, @default_chain_id)

    state = %{
      op_ref: op_ref,
      chain_id: chain,
      privkey: nil,
      address: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:address, _from, state) do
    case ensure_loaded(state) do
      {:ok, state} -> {:reply, state.address, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:chain_id, _from, state) do
    {:reply, state.chain_id, state}
  end

  def handle_call({:sign_message, message}, _from, state) do
    case ensure_loaded(state) do
      {:ok, state} ->
        result = do_sign_message(state.privkey, message)
        {:reply, result, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:sign_typed_data, domain, types, message}, _from, state) do
    case ensure_loaded(state) do
      {:ok, state} ->
        result = do_sign_typed_data(state.privkey, domain, types, message)
        {:reply, result, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # -- Private --

  defp ensure_loaded(%{privkey: key} = state) when is_binary(key), do: {:ok, state}

  defp ensure_loaded(%{op_ref: op_ref} = state) do
    case fetch_from_op(op_ref) do
      {:ok, privkey} ->
        {:ok, pubkey} = ExSecp256k1.create_public_key(privkey)
        address = derive_address(pubkey)
        {:ok, %{state | privkey: privkey, address: address}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_from_op(op_ref) do
    case System.cmd("op", ["read", op_ref], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.trim_leading("0x")
        |> Base.decode16(case: :mixed)
        |> case do
          {:ok, key} when byte_size(key) == 32 -> {:ok, key}
          {:ok, key} -> {:error, {:invalid_key_length, byte_size(key)}}
          :error -> {:error, :invalid_hex_from_op}
        end

      {output, code} ->
        {:error, {:op_failed, code, String.trim(output)}}
    end
  end

  defp derive_address(pubkey) do
    <<_prefix::8, key_bytes::binary>> = pubkey
    <<_first_12::binary-size(12), address_bytes::binary-size(20)>> = ExKeccak.hash_256(key_bytes)
    "0x" <> Base.encode16(address_bytes, case: :lower)
  end

  defp do_sign_message(privkey, message) do
    hash = ExKeccak.hash_256(message)

    case ExSecp256k1.sign(hash, privkey) do
      {:ok, {r, s, v}} ->
        {:ok, <<r::binary-size(32), s::binary-size(32), v::8>>}

      {:error, reason} ->
        {:error, {:sign_failed, reason}}
    end
  end

  defp do_sign_typed_data(privkey, domain, types, message) do
    with {:ok, hash} <- Raxol.Payments.EIP712.hash(domain, types, message) do
      case ExSecp256k1.sign(hash, privkey) do
        {:ok, {r, s, v}} ->
          {:ok, <<r::binary-size(32), s::binary-size(32), v::8>>}

        {:error, reason} ->
          {:error, {:sign_failed, reason}}
      end
    end
  end
end
