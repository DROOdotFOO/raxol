defmodule Raxol.ACP.Wallet.SCA.Provisioner do
  @moduledoc """
  Two-UserOperation provisioning for an Alchemy Modular Account v2 SMA:
  deploy the account, then register its session key.

  `Raxol.ACP.Wallet.SCA.Provisioning` is the pure module (address
  prediction + calldata). This module is the *stateful* driver that
  actually submits the UserOps through a wallet's sponsored-userOp path
  and reads chain state (deployed? / installed?) to stay idempotent.

  ## Flow

  1. **Deploy (op 1)** -- if the account has no bytecode yet, submit a
     UserOp whose `initCode` is the factory `createSemiModularAccount`
     call. The op is authorized by the **owner** (entity 0) key, because
     a freshly-deployed SMA validates against its native owner. The
     callData is **empty** (a deploy-only op); a live bundler that
     rejects empty callData can opt into an `execute(owner, 0, <<>>)`
     no-op via `:deploy_call_data` (see `provision/3` options).

  2. **Install (op 2)** -- if the session key isn't registered yet,
     submit a UserOp whose callData is
     `own_session_key_install_calldata()` used **directly** (NOT wrapped
     in `execute(...)`). MAv2 SMA rejects self-calls with
     `SelfCallRecursionDepthExceeded()` (AA23 / selector `0x54ff929d`).
     This op is also owner-signed and its nonce is **re-queried** from
     the EntryPoint (never locally incremented) -- after op 1's receipt
     the owner sequence has advanced to 1.

  Both checks read chain state, so `ensure_provisioned/3` is safe to call
  before every write: an already-deployed + already-installed account
  submits zero UserOps.

  ## The `installed?` getter is a live gate

  Reading whether a session key is registered goes through the
  single-signer validation module. The exact getter selector is not yet
  verified against the deployed module in-repo, so the default
  `signers(uint32,address)` read is best-effort. Callers can override the
  signature, force the answer with `:assume_installed`, skip the check
  with `:skip_install_check` (attempt install and treat a duplicate
  revert as success), or supply `:treat_install_revert_as_installed`.
  See the `:live_bundler` harness (`bundler_harness_test.exs`) for the
  end-to-end validation against the real EntryPoint.
  """

  alias Raxol.ACP.ABI
  alias Raxol.ACP.Onchain.Hex
  alias Raxol.ACP.Onchain.RPC
  alias Raxol.ACP.Wallet.SCA.{EntryPoint, ModularAccount, UserOp}

  @default_installed_getter "signers(uint32,address)"

  @type status :: :ok | :skipped
  @type result :: %{deploy: status(), install: status()}

  @doc """
  Idempotently ensure the account is deployed and its session key
  installed. Safe to call before every write; skips steps already done.

  Delegates to `provision/3`.
  """
  @spec ensure_provisioned(module(), RPC.client(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def ensure_provisioned(wallet, client, opts \\ []) do
    provision(wallet, client, opts)
  end

  @doc """
  Run the two-op provisioning flow: deploy-if-needed, then
  install-if-needed.

  Returns `{:ok, %{deploy: :ok | :skipped, install: :ok | :skipped}}`.
  If the install op fails after a fresh deploy, returns
  `{:error, {:install_failed, reason}}`; a subsequent call skips the
  (now-complete) deploy and retries the install.

  ## Options

  Threaded verbatim into `wallet.send_sponsored_user_operation/2` and
  `wallet.await_user_operation/2` (so bundler/paymaster stubs flow
  through). Additionally honored here:

  - `:deploy_call_data` -- `:empty` (default) or `:execute_noop`. The
    latter wraps a no-op `execute(owner, 0, <<>>)` for live bundlers that
    reject empty callData on the deploy op.
  - `:assume_installed` -- treat the session key as already registered
    (skip op 2 entirely).
  - `:skip_install_check` -- don't read the module; attempt the install
    op directly (relies on duplicate-revert-as-success).
  - `:installed_getter_signature` -- override the single-signer getter
    signature used to read installation state.
  - `:treat_install_revert_as_installed` -- treat an install-op revert as
    a benign duplicate registration.
  """
  @spec provision(module(), RPC.client(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def provision(wallet, client, opts \\ []) do
    with {:ok, deploy_status} <- ensure_deployed(wallet, client, opts),
         {:ok, install_status} <- ensure_installed(wallet, client, opts) do
      {:ok, %{deploy: deploy_status, install: install_status}}
    end
  end

  # -- Deploy (op 1) --

  defp ensure_deployed(wallet, client, opts) do
    case RPC.deployed?(client, wallet.address()) do
      {:ok, true} -> {:ok, :skipped}
      {:ok, false} -> deploy(wallet, client, opts)
      {:error, _} = err -> err
    end
  end

  defp deploy(wallet, client, opts) do
    with {:ok, nonce} <- owner_nonce(wallet, client) do
      op = %UserOp{
        sender: wallet.address(),
        nonce: nonce,
        init_code: wallet.deploy_init_code(),
        call_data: deploy_call_data(wallet, opts)
      }

      case send_and_await(wallet, op, opts) do
        {:ok, _receipt} -> {:ok, :ok}
        {:error, reason} -> {:error, {:deploy_failed, reason}}
      end
    end
  end

  defp deploy_call_data(wallet, opts) do
    case Keyword.get(opts, :deploy_call_data, :empty) do
      :empty -> <<>>
      :execute_noop -> ModularAccount.execute_calldata(wallet.owner_address(), 0, <<>>)
    end
  end

  # -- Install (op 2) --

  defp ensure_installed(wallet, client, opts) do
    case installed?(wallet, client, opts) do
      {:ok, true} -> {:ok, :skipped}
      {:ok, false} -> install(wallet, client, opts)
      {:error, _} = err -> err
    end
  end

  # Read the single-signer validation module for the session key. The
  # getter selector is a live gate; `:assume_installed` / `:skip_install_check`
  # let callers bypass it.
  defp installed?(wallet, client, opts) do
    cond do
      Keyword.get(opts, :assume_installed, false) -> {:ok, true}
      Keyword.get(opts, :skip_install_check, false) -> {:ok, false}
      true -> query_installed(wallet, client, opts)
    end
  end

  defp query_installed(wallet, client, opts) do
    signature = Keyword.get(opts, :installed_getter_signature, @default_installed_getter)

    # uint32 ABI-encodes identically to uint256 (32-byte word); the
    # selector is taken from the canonical signature string.
    call_data =
      ABI.encode_call(signature, [
        {"uint256", wallet.signer_entity_id()},
        {"address", wallet.address()}
      ])

    call = %{to: ModularAccount.single_signer_validation_address(), data: call_data}

    case RPC.eth_call(client, call) do
      {:ok, hex} -> {:ok, registered?(hex, wallet.owner_address())}
      {:error, _} = err -> err
    end
  end

  # The getter returns the registered signer address in the low 20 bytes
  # of a 32-byte word. Installed iff it matches the owner/session EOA.
  defp registered?("0x" <> hex, owner) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<_::binary-size(12), addr::binary-size(20)>>} ->
        Hex.encode(addr) == String.downcase(owner)

      _ ->
        false
    end
  end

  defp registered?(_, _), do: false

  defp install(wallet, client, opts) do
    case do_install(wallet, client, opts) do
      {:ok, _receipt} ->
        {:ok, :ok}

      {:error, reason} ->
        if duplicate_registration?(reason, opts) do
          {:ok, :ok}
        else
          {:error, {:install_failed, reason}}
        end
    end
  end

  defp do_install(wallet, client, opts) do
    # Re-query the owner nonce: after op 1's receipt the owner sequence is
    # 1. Never locally increment -- a stale nonce strands the op.
    with {:ok, nonce} <- owner_nonce(wallet, client) do
      op = %UserOp{
        sender: wallet.address(),
        nonce: nonce,
        init_code: <<>>,
        # NOT wrapped in execute(...) -- MAv2 SMA rejects self-calls with
        # SelfCallRecursionDepthExceeded() (AA23 / 0x54ff929d).
        call_data: wallet.own_session_key_install_calldata()
      }

      send_and_await(wallet, op, opts)
    end
  end

  # A re-registration of an existing entity reverts. Treat it as success
  # only when the caller opts in (the exact revert shape is unverified).
  defp duplicate_registration?(reason, opts) do
    Keyword.get(opts, :treat_install_revert_as_installed, false) or duplicate_marker?(reason)
  end

  defp duplicate_marker?({:rpc_error, _code, msg}) when is_binary(msg) do
    msg = String.downcase(msg)
    String.contains?(msg, "already") or String.contains?(msg, "0x54ff929d")
  end

  defp duplicate_marker?(_), do: false

  # -- Shared --

  # Owner (native entity-0) nonce key. Provisioning ops are owner-signed;
  # the write path uses the session-entity key (wallet.nonce_key/0).
  defp owner_nonce(wallet, client) do
    key = ModularAccount.nonce_key(0, true)
    EntryPoint.get_nonce(client, wallet.entry_point(), wallet.address(), key)
  end

  defp send_and_await(wallet, %UserOp{} = op, opts) do
    with {:ok, op_hash} <- wallet.send_sponsored_user_operation(op, opts) do
      wallet.await_user_operation(op_hash, opts)
    end
  end
end
