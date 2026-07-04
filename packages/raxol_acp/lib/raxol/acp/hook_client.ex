defmodule Raxol.ACP.HookClient do
  @moduledoc """
  High-level wrapper around `Raxol.ACP.ProviderAdapter` for the v2 ACP
  Core hook calls.

  The acp-node-v2 selectors (verified against
  https://github.com/Virtual-Protocol/acp-node-v2/blob/main/src/core/constants.ts):

      setBudget(uint256, uint256, bytes)
      fund(uint256, uint256, bytes)
      submit(uint256, bytes32, bytes)
      complete(uint256, bytes32, bytes)
      reject(uint256, bytes32, bytes)

  Plus `createJob`, which targets ACP Core but takes the offering /
  hook configuration as parameters.

  All of these route through whichever `Raxol.ACP.ProviderAdapter` the
  caller supplies, so this module doesn't care whether the underlying
  signer is our Elixir-native SCA or something else.

  ## On the `bytes data` parameter

  ACP Core's hook functions take a trailing `bytes data` arg whose
  contents are interpreted by the configured hook contract. For
  `FundTransferHook`, `setBudget(jobId, amount, data)` encodes
  `(transferAmount, destination)` in `data`. For
  `SubscriptionHook`, `data` carries `packageId`. Callers pass the
  pre-encoded bytes; this module doesn't try to abstract over the
  variants -- that's the offering's job.
  """

  alias Raxol.ACP.ProviderAdapter

  @type chain_id :: pos_integer()
  @type job_id :: non_neg_integer()
  @type token_amount :: non_neg_integer()
  @type bytes32 :: binary()
  @type tx_hash :: String.t()

  # -- Action functions --

  @doc """
  Submit `setBudget(jobId, amount, data)` to the ACP Core contract on
  `chain_id`. `acp_core_address` is the deployed ACP Core address;
  caller usually reads it from `Raxol.ACP.Chain.mainnet/0`.
  """
  @spec set_budget(
          ProviderAdapter.adapter(),
          chain_id(),
          String.t(),
          job_id(),
          token_amount(),
          binary()
        ) :: {:ok, tx_hash()} | {:error, term()}
  def set_budget(adapter, chain_id, acp_core_address, job_id, amount, data \\ <<>>) do
    submit_single(adapter, chain_id, acp_core_address, "setBudget(uint256,uint256,bytes)", [
      {"uint256", job_id},
      {"uint256", amount},
      {"bytes", data}
    ])
  end

  @doc "Submit `fund(jobId, amount, data)`."
  @spec fund(
          ProviderAdapter.adapter(),
          chain_id(),
          String.t(),
          job_id(),
          token_amount(),
          binary()
        ) :: {:ok, tx_hash()} | {:error, term()}
  def fund(adapter, chain_id, acp_core_address, job_id, amount, data \\ <<>>) do
    submit_single(adapter, chain_id, acp_core_address, "fund(uint256,uint256,bytes)", [
      {"uint256", job_id},
      {"uint256", amount},
      {"bytes", data}
    ])
  end

  @doc """
  Submit `submit(jobId, deliverableHash, data)`.

  `deliverable_hash` is a 32-byte commitment to the deliverable
  payload. By convention this is `keccak256(canonical_json(deliverable))`.
  """
  @spec submit(
          ProviderAdapter.adapter(),
          chain_id(),
          String.t(),
          job_id(),
          bytes32(),
          binary()
        ) :: {:ok, tx_hash()} | {:error, term()}
  def submit(adapter, chain_id, acp_core_address, job_id, deliverable_hash, data \\ <<>>) do
    submit_single(adapter, chain_id, acp_core_address, "submit(uint256,bytes32,bytes)", [
      {"uint256", job_id},
      {"bytes32", encode_bytes32(deliverable_hash)},
      {"bytes", data}
    ])
  end

  @doc "Submit `complete(jobId, deliverableHash, data)`."
  @spec complete(
          ProviderAdapter.adapter(),
          chain_id(),
          String.t(),
          job_id(),
          bytes32(),
          binary()
        ) :: {:ok, tx_hash()} | {:error, term()}
  def complete(adapter, chain_id, acp_core_address, job_id, deliverable_hash, data \\ <<>>) do
    submit_single(adapter, chain_id, acp_core_address, "complete(uint256,bytes32,bytes)", [
      {"uint256", job_id},
      {"bytes32", encode_bytes32(deliverable_hash)},
      {"bytes", data}
    ])
  end

  @doc "Submit `reject(jobId, deliverableHash, data)`."
  @spec reject(
          ProviderAdapter.adapter(),
          chain_id(),
          String.t(),
          job_id(),
          bytes32(),
          binary()
        ) :: {:ok, tx_hash()} | {:error, term()}
  def reject(adapter, chain_id, acp_core_address, job_id, deliverable_hash, data \\ <<>>) do
    submit_single(adapter, chain_id, acp_core_address, "reject(uint256,bytes32,bytes)", [
      {"uint256", job_id},
      {"bytes32", encode_bytes32(deliverable_hash)},
      {"bytes", data}
    ])
  end

  @doc """
  Submit `createJob(...)` on ACP Core.

  Matches the deployed `AgenticCommerceV3` core (Blockscout-verified on Base):

      createJob(address provider, address evaluator, uint256 expiredAt,
                string description, address hook)

  `hook` is the whitelisted hook contract (e.g. the FundTransferHook).
  Per-call hook parameters are NOT passed here -- `createJob` takes no
  `hookData`; the hook `optParams` flow through `setBudget`/`fund`/`submit`/
  `complete` instead. `description` is the job's human-readable string
  (defaults to `""`).

  Returns the assigned jobId via a separate `getJobIdFromTxHash` call
  in the SDK; this function returns the tx hash and lets the caller
  resolve the jobId.
  """
  @spec create_job(
          ProviderAdapter.adapter(),
          chain_id(),
          String.t(),
          %{
            required(:provider) => String.t(),
            required(:evaluator) => String.t(),
            required(:expired_at) => non_neg_integer(),
            required(:hook_address) => String.t(),
            optional(:description) => String.t()
          }
        ) :: {:ok, tx_hash()} | {:error, term()}
  def create_job(
        adapter,
        chain_id,
        acp_core_address,
        %{
          provider: provider,
          evaluator: evaluator,
          expired_at: expired_at,
          hook_address: hook_address
        } = params
      ) do
    description = Map.get(params, :description, "")

    submit_single(
      adapter,
      chain_id,
      acp_core_address,
      "createJob(address,address,uint256,string,address)",
      [
        {"address", provider},
        {"address", evaluator},
        {"uint256", expired_at},
        {"string", description},
        {"address", hook_address}
      ]
    )
  end

  # -- Internals --

  defp submit_single(adapter, chain_id, to, signature, args) do
    data = Raxol.ACP.ABI.encode_call(signature, args)

    call = %{
      to: to,
      data: data,
      value: 0
    }

    case ProviderAdapter.send_calls(adapter, chain_id, [call]) do
      {:ok, [tx_hash]} -> {:ok, tx_hash}
      {:ok, [tx_hash | _]} -> {:ok, tx_hash}
      {:ok, []} -> {:error, :no_tx_hash_returned}
      err -> err
    end
  end

  # `Raxol.ACP.ABI.encode_bytes32` accepts hex (with or without 0x);
  # normalize raw 32-byte binaries to hex so both representations work.
  defp encode_bytes32(<<_::binary-size(32)>> = bytes),
    do: "0x" <> Base.encode16(bytes, case: :lower)

  defp encode_bytes32("0x" <> hex = full) when byte_size(hex) == 64, do: full

  defp encode_bytes32(other),
    do:
      raise(
        ArgumentError,
        "bytes32 value must be 32 raw bytes or 66-char hex, got: #{inspect(other)}"
      )
end
