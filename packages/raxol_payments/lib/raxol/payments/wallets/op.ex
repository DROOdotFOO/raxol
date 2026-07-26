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

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Payments.Secret

  @default_chain_id 8453

  # -- Public API --

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

  @doc """
  Sign a precomputed 32-byte digest. Mirrors `Raxol.Payments.Wallet.sign_hash/1`
  with a server argument; used by EIP-1559 transaction signing.
  """
  @spec sign_hash(GenServer.server(), <<_::256>>) ::
          {:ok, binary()} | {:error, term()}
  def sign_hash(server, <<_::binary-size(32)>> = digest) do
    GenServer.call(server, {:sign_hash, digest})
  end

  # -- BaseManager callbacks --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
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

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:address, _from, state) do
    case ensure_loaded(state) do
      {:ok, state} -> {:reply, state.address, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_manager_call(:chain_id, _from, state) do
    {:reply, state.chain_id, state}
  end

  def handle_manager_call({:sign_message, message}, _from, state) do
    case ensure_loaded(state) do
      {:ok, state} ->
        result =
          Secret.with_revealed(state.privkey, &do_sign_message(&1, message))

        {:reply, result, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_manager_call(
        {:sign_typed_data, domain, types, message},
        _from,
        state
      ) do
    case ensure_loaded(state) do
      {:ok, state} ->
        result =
          Secret.with_revealed(
            state.privkey,
            &do_sign_typed_data(&1, domain, types, message)
          )

        {:reply, result, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_manager_call({:sign_hash, digest}, _from, state) do
    case ensure_loaded(state) do
      {:ok, state} ->
        result = Secret.with_revealed(state.privkey, &do_sign_hash(&1, digest))
        {:reply, result, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # -- Private --

  defp ensure_loaded(%{privkey: %Secret{}} = state), do: {:ok, state}

  defp ensure_loaded(%{op_ref: op_ref} = state) do
    # Wrap the fetched key in `Secret` immediately, so the raw bytes only leave
    # the wrapper inside `with_revealed` (which contains any NIF raise). A
    # non-`{:ok, _}` return from the NIF now fails the load gracefully instead of
    # crashing the wallet on a bad key.
    with {:ok, privkey} <- fetch_from_op(op_ref),
         secret = Secret.new(privkey),
         {:ok, pubkey} <-
           Secret.with_revealed(secret, &ExSecp256k1.create_public_key/1) do
      {:ok,
       %{
         state
         | privkey: secret,
           address: Raxol.Payments.EIP712.address_from_pubkey(pubkey)
       }}
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

  defp do_sign_message(privkey, message) do
    hash = ExKeccak.hash_256(message)

    case ExSecp256k1.sign(hash, privkey) do
      {:ok, signature} ->
        {:ok, Raxol.Payments.EIP712.pack_signature(signature)}

      {:error, reason} ->
        {:error, {:sign_failed, reason}}
    end
  end

  defp do_sign_typed_data(privkey, domain, types, message) do
    with {:ok, hash} <- Raxol.Payments.EIP712.hash(domain, types, message) do
      case ExSecp256k1.sign(hash, privkey) do
        {:ok, signature} ->
          {:ok, Raxol.Payments.EIP712.pack_signature(signature)}

        {:error, reason} ->
          {:error, {:sign_failed, reason}}
      end
    end
  end

  defp do_sign_hash(privkey, <<_::binary-size(32)>> = digest) do
    case ExSecp256k1.sign(digest, privkey) do
      {:ok, signature} ->
        {:ok, Raxol.Payments.EIP712.pack_signature(signature)}

      {:error, reason} ->
        {:error, {:sign_failed, reason}}
    end
  end
end
