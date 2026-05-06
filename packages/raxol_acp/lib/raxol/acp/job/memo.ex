defmodule Raxol.ACP.Job.Memo do
  @moduledoc """
  EIP-712 typed-data construction and signing for ACP memos.

  Every state transition in the ACP job lifecycle produces a signed
  memo on Base. This module builds the typed-data envelope and signs
  it via any module implementing `Raxol.Payments.Wallet`.

  ## What this module owns

  - The EIP-712 `EIP712Domain` for the ACP contract (name, version,
    chainId, verifyingContract).
  - The `Memo` type schema -- jobId, memoType, payloadHash.
  - Coercion of arbitrary job ids to a `uint256` slot (numeric ids
    pass through; non-numeric ids are hashed).

  ## What this module does NOT own

  Payload canonicalization. ACP memos sign a `payloadHash` (bytes32),
  not the raw payload. The caller is responsible for producing that
  hash in whatever format the contract expects -- typically
  `keccak256` of a canonical encoding of the payload. This avoids
  guessing canonicalization rules before we have the real ACP
  contract source available, and keeps the memo module testable in
  isolation.

  ## Schema (v0.1)

  Domain:

      EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)

  Memo type:

      Memo(uint256 jobId,string memoType,bytes32 payloadHash)

  When the real ACP ABIs are vendored, this schema may change. The
  property test against the Node SDK's hash output (planned for the
  v0.1 milestone) is the canonical source of truth for correctness.
  """

  alias Raxol.Payments.EIP712

  @type memo_type :: Raxol.ACP.ContractClient.memo_type()
  @type job_id :: binary() | non_neg_integer()
  @type payload_hash :: binary()
  @type typed_data :: {map(), map(), map()}
  @type sign_opts :: [
          chain_id: pos_integer(),
          verifying_contract: String.t(),
          name: String.t(),
          version: String.t()
        ]

  @default_name "Virtuals ACP"
  @default_version "2"

  @memo_types %{
    "Memo" => [
      {"jobId", "uint256"},
      {"memoType", "string"},
      {"payloadHash", "bytes32"}
    ]
  }

  @doc """
  Build the EIP-712 typed-data tuple for an ACP memo.

  ## Required options

  - `:chain_id` -- e.g. `8453` for Base mainnet.
  - `:verifying_contract` -- the deployed ACP contract address.

  ## Optional

  - `:name` -- domain name (default `"Virtuals ACP"`).
  - `:version` -- domain version (default `"2"`).
  """
  @spec typed_data(job_id(), memo_type(), payload_hash(), sign_opts()) :: typed_data()
  def typed_data(job_id, memo_type, payload_hash, opts) do
    domain = %{
      name: Keyword.get(opts, :name, @default_name),
      version: Keyword.get(opts, :version, @default_version),
      chainId: Keyword.fetch!(opts, :chain_id),
      verifyingContract: Keyword.fetch!(opts, :verifying_contract)
    }

    message = %{
      jobId: job_id_to_uint(job_id),
      memoType: Atom.to_string(memo_type),
      payloadHash: payload_hash
    }

    {domain, @memo_types, message}
  end

  @doc """
  Sign a typed-data tuple with the given wallet module.

  The wallet must implement `Raxol.Payments.Wallet` -- both the
  bundled `Wallets.Env` and `Wallets.Op` work, as does any custom
  impl. Returns `{:ok, signature}` (65 bytes: r ++ s ++ v) or
  `{:error, term}`.
  """
  @spec sign(typed_data(), module()) :: {:ok, binary()} | {:error, term()}
  def sign({domain, types, message}, wallet) when is_atom(wallet) do
    wallet.sign_typed_data(domain, types, message)
  end

  @doc """
  Convenience: build the typed-data and sign in one call.

  Returns `{:ok, %{message: map, signature: binary}}` so the caller
  has both the message struct (for ContractClient.submit_memo's
  payload arg) and the signature.
  """
  @spec build_and_sign(job_id(), memo_type(), payload_hash(), module(), sign_opts()) ::
          {:ok, %{message: map(), signature: binary()}} | {:error, term()}
  def build_and_sign(job_id, memo_type, payload_hash, wallet, opts) do
    {_domain, _types, message} = td = typed_data(job_id, memo_type, payload_hash, opts)

    case sign(td, wallet) do
      {:ok, signature} -> {:ok, %{message: message, signature: signature}}
      {:error, _} = err -> err
    end
  end

  @doc """
  Compute the 32-byte EIP-712 digest for a typed-data tuple without
  signing it.

  Useful for off-line verification: hash here, sign elsewhere, recover
  the signer with `secp256k1` and assert the address matches.
  """
  @spec digest(typed_data()) :: {:ok, binary()} | {:error, term()}
  def digest({domain, types, message}) do
    EIP712.hash(domain, types, message)
  end

  # -- Private --

  defp job_id_to_uint(n) when is_integer(n) and n >= 0, do: n

  defp job_id_to_uint(bin) when is_binary(bin) do
    case Integer.parse(bin) do
      {n, ""} when n >= 0 ->
        n

      _ ->
        # Synthetic ids like "job-1" (from the InMemory contract client) get
        # hashed into a deterministic uint256. Real ACP job ids returned by
        # an Onchain client are decimal-encoded integers and pass through
        # the integer-parse branch above.
        <<n::unsigned-big-256>> = ExKeccak.hash_256(bin)
        n
    end
  end
end
