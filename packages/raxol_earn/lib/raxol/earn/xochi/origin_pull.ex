defmodule Raxol.Earn.Xochi.OriginPull do
  @moduledoc """
  Decide, and grant, the origin-pull allowance a Xochi quote needs before the
  buyer signs it.

  Every pulling quote serves a `pull_authorization` the buyer signs so the solver
  can collect the origin funds. Two rails, with different on-chain guarantees:

    * `erc3009` -- the signed authorization names the recipient and the token
      enforces `msg.sender == to`, so the chain bounds the destination. No
      standing allowance exists to grant.
    * `permit2` -- the buyer must already hold a standing ERC-20 allowance for
      the universal Permit2 contract, and the `spender` named in the permit
      chooses the recipient at call time. There is NO on-chain recipient guard.

  The rail is read from the quote's `payment_method`, never guessed from the
  token: a smart-account (ERC-1271) buyer pulls USDC through Permit2, where an
  EOA buyer of the same token pulls through ERC-3009.

  Because Permit2 has no on-chain recipient guard, the pinned spender is the only
  destination control on that rail. `allowance_plan/2` therefore refuses a Permit2
  quote unless the operator named the spender they expect AND the quote served
  exactly that spender. Granting an allowance towards an unpinned spender is the
  one thing this module will not do.
  """

  alias Raxol.Earn.Onchain.Permit2Approver
  alias Raxol.Earn.ProviderAdapter
  alias Raxol.Payments.EIP712

  @typedoc "What the origin pull needs before the intent is signed."
  @type plan :: :not_needed | {:permit2, String.t()}

  @typedoc "What ensuring the allowance did (or, under `:dry_run`, would do)."
  @type outcome ::
          :not_needed | :standing | :would_approve | {:approved, String.t()}

  @doc """
  Decide what allowance a served quote needs, given the operator's pinned spender.

  `{:ok, :not_needed}` for a non-pulling quote and for the ERC-3009 rail;
  `{:ok, {:permit2, spender}}` when the quote's Permit2 spender matches the pin.
  Fails closed otherwise -- an unpinned or mismatched spender never becomes an
  allowance.
  """
  @spec allowance_plan(map(), String.t() | nil) :: {:ok, plan()} | {:error, term()}
  def allowance_plan(quote_resp, pinned_spender)

  def allowance_plan(%{pull_authorization: nil}, _pinned), do: {:ok, :not_needed}

  def allowance_plan(%{pull_authorization: pull, payment_method: "permit2"}, pinned),
    do: permit2_plan(served_spender(pull), pinned)

  def allowance_plan(%{payment_method: "erc3009"}, _pinned), do: {:ok, :not_needed}

  def allowance_plan(%{payment_method: other}, _pinned),
    do: {:error, {:unsupported_pull_method, other}}

  @doc """
  Ensure the buyer holds the allowance `plan` calls for.

  Idempotent: a standing allowance answers `{:ok, :standing}` and sends nothing.
  With `dry_run: true` the allowance is only READ, so a rehearsal reports
  `:would_approve` instead of broadcasting one. Remaining options are passed to
  `Raxol.Earn.Onchain.Permit2Approver.ensure_allowance/5`.
  """
  @spec ensure_allowance(
          plan(),
          ProviderAdapter.adapter(),
          pos_integer(),
          String.t(),
          String.t(),
          keyword()
        ) :: {:ok, outcome()} | {:error, term()}
  def ensure_allowance(plan, provider, chain_id, token, owner, opts \\ [])

  def ensure_allowance(:not_needed, _provider, _chain_id, _token, _owner, _opts),
    do: {:ok, :not_needed}

  def ensure_allowance({:permit2, _spender}, provider, chain_id, token, owner, opts) do
    {dry_run?, approve_opts} = Keyword.pop(opts, :dry_run, false)
    ensure(dry_run?, provider, chain_id, token, owner, approve_opts)
  end

  @doc "One log line describing what `ensure_allowance/6` did."
  @spec describe(outcome()) :: String.t()
  def describe(:not_needed),
    do: "origin pull: ERC-3009 rail -- no Permit2 allowance to grant"

  def describe(:standing),
    do: "origin pull: Permit2 allowance already standing -- no approve sent"

  def describe(:would_approve),
    do:
      "origin pull: Permit2 allowance is SHORT -- a funded run would send one " <>
        "approve(Permit2) UserOp before signing"

  def describe({:approved, hash}),
    do: "origin pull: granted the Permit2 allowance, approve tx #{hash}"

  @doc """
  Operator-facing explanation of an `allowance_plan/2` refusal.

  Every message names the input the operator has to supply and where to confirm
  it, because a fail-closed run is only useful if it says what would unblock it.
  """
  @spec explain(term()) :: String.t()
  def explain(:unpinned_permit2_spender) do
    """
    this quote's origin pull is Permit2, and no spender is pinned.

    Permit2 has no on-chain recipient guard: the spender chooses where the pulled
    funds go at call time, so the pinned spender is the ONLY destination control
    on this rail. Name the spender you expect and re-run:

      mix raxol_earn.order --solver 0x<spender> ...     (or ORDER_SOLVER=0x<spender>)

    Take that address from Riddler's XochiPull deployment record, not from a quote
    -- a served spender is exactly the value the pin exists to check.
    """
  end

  def explain({:pull_spender_mismatch, served, pinned}) do
    """
    this quote's Permit2 spender is #{served}, but the pinned spender is #{pinned}.

    Nothing was signed and no allowance was granted. Either the solver rotated its
    pull contract -- confirm the new address against Riddler's XochiPull deployment
    record and re-run with `--solver #{served}` -- or this quote is not the one you
    meant to sign.
    """
  end

  def explain({:invalid_spender, :pinned, value}) do
    """
    the pinned spender #{inspect(value)} is not a 20-byte 0x-hex address.

    Pass the solver's Permit2 spender as `--solver 0x<40 hex chars>` (or
    ORDER_SOLVER), taken from Riddler's XochiPull deployment record.
    """
  end

  def explain({:invalid_spender, :served, value}) do
    """
    this quote's Permit2 authorization carries no usable spender (#{inspect(value)}).

    Nothing was signed. A Permit2 permit with no spender cannot be checked against
    the pin, so it is refused rather than signed blind.
    """
  end

  def explain({:unsupported_pull_method, method}) do
    """
    this quote serves an origin pull on the unsupported rail #{inspect(method)}.

    Only `erc3009` and `permit2` pulls are understood here, and an unknown rail's
    destination controls are unknown too, so it is refused rather than signed.
    """
  end

  # Reading the allowance, or granting it, can fail for reasons that belong to the
  # chain rather than to this decision. Report those verbatim: a reason with no
  # tailored message must still reach the operator.
  def explain(reason) do
    """
    the origin-pull allowance could not be settled: #{inspect(reason)}

    Nothing was signed. This is the allowance read or the approve itself failing,
    so check the origin chain's RPC and whether the buyer can send a UserOp there.
    """
  end

  # -- Internal --

  defp permit2_plan(_served, pinned) when pinned in [nil, ""],
    do: {:error, :unpinned_permit2_spender}

  defp permit2_plan(served, pinned) do
    with {:ok, served_addr} <- address(served, :served),
         {:ok, pinned_addr} <- address(pinned, :pinned) do
      compare(served_addr, pinned_addr, served)
    end
  end

  defp compare(addr, addr, served), do: {:ok, {:permit2, served}}

  defp compare(served_addr, pinned_addr, _served),
    do: {:error, {:pull_spender_mismatch, "0x" <> served_addr, "0x" <> pinned_addr}}

  defp served_spender(pull) when is_map(pull), do: get_in(pull, ["message", "spender"])
  defp served_spender(_pull), do: nil

  # A canonical 20-byte hex address, matching what the payments-side pin compares.
  @address ~r/\A[0-9a-f]{40}\z/

  defp address(value, role) when is_binary(value) do
    normalized = EIP712.normalize_address(value)

    case Regex.match?(@address, normalized) do
      true -> {:ok, normalized}
      false -> {:error, {:invalid_spender, role, value}}
    end
  end

  defp address(value, role), do: {:error, {:invalid_spender, role, value}}

  # A rehearsal reads the allowance and answers with the same threshold the
  # funded path applies, so `--dry-run` cannot promise a different run.
  defp ensure(true, provider, chain_id, token, owner, opts) do
    min_required = Keyword.get(opts, :min_allowance, Permit2Approver.allowance_floor())

    with {:ok, current} <- Permit2Approver.allowance(provider, chain_id, token, owner) do
      {:ok, rehearsed(current >= min_required)}
    end
  end

  defp ensure(false, provider, chain_id, token, owner, opts) do
    with {:ok, result} <-
           Permit2Approver.ensure_allowance(provider, chain_id, token, owner, opts) do
      {:ok, granted(result)}
    end
  end

  defp rehearsed(true), do: :standing
  defp rehearsed(false), do: :would_approve

  defp granted(:sufficient), do: :standing
  defp granted({:approved, hash}), do: {:approved, hash}
end
