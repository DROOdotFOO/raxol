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
  destination control on that rail. `allowance_plan/3` therefore refuses a Permit2
  quote unless the operator named the spender they expect AND the quote served
  exactly that spender. Granting an allowance towards an unpinned spender is the
  one thing this module will not do.

  ## That refusal binds this module's callers, and no one else

  Read the sentence above as scoped, because the signing layer underneath applies
  a WEAKER rule. `Raxol.Payments.Protocols.Xochi`'s `validate_permit2_pull/2` asks
  only that the spender be in `:pull_solver_allowlist`, and both `config/runtime.exs`
  and the live solver-fee gate populate that list from
  `Raxol.Payments.Xochi.PullContracts.pull_recipients/0` -- the checked-in mirror,
  which contains the Permit2 pull proxy. So `XochiProtocol.quote_and_sign/3`
  called directly WILL sign a Permit2 pull naming that proxy with no operator
  input at all.

  That is deliberate at this stage and not something this module can close from
  here: a mirror of a deployment record is a reasonable default for a server that
  has no operator at the keyboard, and tightening it would stop existing
  deployments settling. What it means for anyone adding a new caller is that the
  operator pin arrives with THIS module and not with the signature. Route through
  `allowance_plan/3` before signing, or the pin is simply absent.

  ## The served permit decides nothing on its own

  A quote is served by a remote solver, so every field the allowance depends on is
  cross-checked against what the OPERATOR asked for before any of it is acted on:
  the permit's `domain.chainId` and `permitted.token` must be the origin chain and
  token of the transfer being ordered, and `permitted.amount` must not exceed the
  origin amount the operator intended. A permit that disagrees is refused rather
  than approved for, because the allowance is granted on the origin chain for the
  origin token and would otherwise be sized by the counterparty.

  ## The allowance is bounded, not a standing max

  The conventional Permit2 pattern is one max ERC-20 approve per token, on the
  reasoning that each `PermitWitnessTransferFrom` signature carries its own
  spender/amount/deadline and is therefore the real bound. That reasoning assumes
  a human reviews each signature. Here the signer is an agent's delegated
  authority signing whatever a quote serves, so a standing max approve would turn
  any single bad signature into a loss of the whole origin balance.

  So the approve is for exactly this intent's authorized pull, which caps the
  blast radius at the amount already being ordered. It costs one approve per run,
  since the pull spends the allowance down to zero. An allowance that is already
  large enough -- including a standing max granted out of band -- is left alone
  and sends nothing, so an operator who prefers the conventional pattern is not
  fought, only never given it by default.

  ## The decision is early; the effect need not be

  Refusing happens before the signature -- an allowance towards an unverified
  spender is what this exists to prevent, so `allowance_plan/3` runs while there
  is still nothing signed to regret. The GRANT is a separate question, because
  the allowance is not needed until the solver pulls, which is at settlement.

  Two effect shapes, for two kinds of caller:

    * `ensure_allowance/4` broadcasts the approve on its own. Right for a buyer
      that can simply send a transaction.
    * `allowance_status/3` + `approve_calls/1` hand the approve back as calls to
      batch into a write the caller was already making. Right for a sponsored
      ERC-4337 buyer, whose paymaster refuses a standalone approve to a token
      contract -- and better besides, since batching lands the allowance in the
      same transaction rather than an earlier one that could be the only leg to
      land.

  Both are bounded by the same plan and both send nothing when the allowance
  already covers the pull.
  """

  alias Raxol.Earn.Onchain.Permit2Approver
  alias Raxol.Earn.ProviderAdapter
  alias Raxol.Payments.EIP712

  @typedoc "The transfer the operator asked for, which the served permit must match."
  @type origin :: %{
          required(:chain_id) => pos_integer(),
          required(:token) => String.t(),
          required(:amount) => non_neg_integer() | String.t()
        }

  @typedoc "A cross-checked Permit2 pull: what to approve, where, and for how much."
  @type permit :: %{
          spender: String.t(),
          chain_id: pos_integer(),
          token: String.t(),
          amount: non_neg_integer()
        }

  @typedoc "What the origin pull needs before the intent is signed."
  @type plan :: :not_needed | {:permit2, permit()}

  @typedoc "What the pull still needs, read against the buyer's current allowance."
  @type status :: :not_needed | :standing | {:short, permit()}

  @typedoc "What ensuring the allowance did (or, under `:dry_run`, would do)."
  @type outcome ::
          :not_needed
          | :standing
          | {:would_approve, non_neg_integer()}
          | {:approved, non_neg_integer(), String.t()}

  @doc """
  Decide what allowance a served quote needs, given the operator's pinned spender
  and the origin leg they intended.

  `{:ok, :not_needed}` for a non-pulling quote and for the ERC-3009 rail;
  `{:ok, {:permit2, permit}}` when the quote's Permit2 spender matches the pin and
  its chain, token and amount match `origin`. Fails closed otherwise -- an
  unpinned, mismatched or oversized permit never becomes an allowance.
  """
  @spec allowance_plan(map(), String.t() | nil, origin()) :: {:ok, plan()} | {:error, term()}
  def allowance_plan(quote_resp, pinned_spender, origin)

  def allowance_plan(%{pull_authorization: nil}, _pinned, _origin), do: {:ok, :not_needed}

  def allowance_plan(%{pull_authorization: pull, payment_method: "permit2"}, pinned, origin),
    do: permit2_plan(pull, pinned, origin)

  def allowance_plan(%{payment_method: "erc3009"}, _pinned, _origin), do: {:ok, :not_needed}

  def allowance_plan(%{payment_method: other}, _pinned, _origin),
    do: {:error, {:unsupported_pull_method, other}}

  @doc """
  Read the buyer's current allowance and say what the pull still needs.

  Never writes. The counterpart to `ensure_allowance/4` for a caller that grants
  the allowance inside a write of its own: it decides whether an approve is
  needed and at what bound, and `approve_calls/1` turns that into the calls to
  batch. A read that fails is returned as an error rather than assumed short,
  because approving on a guess is the one thing this module will not do.
  """
  @spec allowance_status(plan(), ProviderAdapter.adapter(), String.t()) ::
          {:ok, status()} | {:error, term()}
  def allowance_status(plan, provider, owner)

  def allowance_status(:not_needed, _provider, _owner), do: {:ok, :not_needed}

  def allowance_status({:permit2, permit}, provider, owner) do
    with {:ok, current} <-
           Permit2Approver.allowance(provider, permit.chain_id, permit.token, owner) do
      {:ok, covered(current >= permit.amount, permit)}
    end
  end

  defp covered(true, _permit), do: :standing
  defp covered(false, permit), do: {:short, permit}

  @doc """
  The `approve` calls that close a `{:short, _}` status, for the caller to batch
  into its own write. Empty for every other status, so an allowance that already
  covers the pull still sends nothing.

  The amount is the permit's, which `allowance_plan/3` already bounded to the
  transfer the operator asked for -- batching moves WHERE the approve lands,
  never how much it grants.
  """
  @spec approve_calls(status()) :: [ProviderAdapter.call()]
  def approve_calls({:short, permit}),
    do: [Permit2Approver.approve_call(permit.token, permit.amount)]

  def approve_calls(status) when status in [:not_needed, :standing], do: []

  @doc """
  Ensure the buyer holds the allowance `plan` calls for, in a write of its own.

  The plan carries the chain, token and amount that were cross-checked against the
  operator's intent, so this cannot act on a different leg than the one that was
  decided. Idempotent: an allowance that already covers the pull answers
  `{:ok, :standing}` and sends nothing. With `dry_run: true` the allowance is only
  READ, so a rehearsal reports `{:would_approve, amount}` instead of broadcasting
  one.

  Use this only where a lone approve is broadcastable. A sponsored ERC-4337 buyer
  should batch instead (`allowance_status/3` + `approve_calls/1`): the Virtuals
  paymaster refuses a standalone approve to a token contract, so on that path the
  approve has to ride in a UserOp that also carries a call the paymaster accepts.
  """
  @spec ensure_allowance(plan(), ProviderAdapter.adapter(), String.t(), keyword()) ::
          {:ok, outcome()} | {:error, term()}
  def ensure_allowance(plan, provider, owner, opts \\ [])

  def ensure_allowance(:not_needed, _provider, _owner, _opts), do: {:ok, :not_needed}

  def ensure_allowance({:permit2, permit}, provider, owner, opts),
    do: ensure(Keyword.get(opts, :dry_run, false), provider, permit, owner)

  @doc "One log line describing an `allowance_status/3` or an `ensure_allowance/4` result."
  @spec describe(status() | outcome()) :: String.t()
  def describe(:not_needed),
    do: "origin pull: not a Permit2 pull -- no allowance to grant"

  def describe(:standing),
    do:
      "origin pull: the standing Permit2 allowance already covers this intent's pull " <>
        "-- no approve sent"

  # Where the approve then lands is the caller's, since only it knows whether it
  # has a write to batch into.
  def describe({:short, permit}),
    do:
      "origin pull: Permit2 allowance is SHORT -- an approve for exactly #{permit.amount} " <>
        "base units (this intent's authorized pull) is needed before the solver can pull"

  def describe({:would_approve, amount}),
    do:
      "origin pull: Permit2 allowance is SHORT -- a funded run would approve exactly " <>
        "#{amount} base units (this intent's authorized pull) before signing"

  def describe({:approved, amount, hash}),
    do:
      "origin pull: approved exactly #{amount} base units for Permit2 " <>
        "(this intent's authorized pull), approve tx #{hash}"

  @doc """
  Operator-facing explanation of an `allowance_plan/3` refusal.

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

  # The served address is NAMED but never formatted as the fix. Printing
  # `--solver <served>` here would hand back a ready-to-run command that grants a
  # real allowance towards whatever the counterparty asked for, one paste after
  # being told the pin exists to check exactly that value.
  def explain({:pull_spender_mismatch, served, pinned}) do
    """
    this quote's Permit2 spender is #{served}, but the pinned spender is #{pinned}.

    Nothing was signed and no allowance was granted.

    Do NOT re-run with the served address because it appears above -- checking it
    is the entire point of the pin. Either this quote is not the one you meant to
    sign, or the solver rotated its pull contract. Only the second is a reason to
    change the pin, and only after the new address matches Riddler's XochiPull
    deployment record. Take the value from that record, not from this message.
    """
  end

  def explain({:pull_chain_mismatch, served, intended}) do
    """
    this quote's Permit2 permit is for chain #{inspect(served)}, but the transfer
    being ordered leaves chain #{intended}.

    Nothing was signed and no allowance was granted. The allowance is granted on
    the origin chain, so a permit naming a different one either belongs to another
    corridor or is not the quote you asked for. Check --corridor.
    """
  end

  def explain({:pull_token_mismatch, served, intended}) do
    """
    this quote's Permit2 permit pulls #{inspect(served)}, but the transfer being
    ordered sends #{intended}.

    Nothing was signed and no allowance was granted. The allowance is granted for
    the origin token, so approving for a token the operator never named would let
    the pull reach a balance this run was not about.
    """
  end

  def explain({:pull_amount_unbounded, served, intended}) do
    """
    this quote's Permit2 permit authorizes #{inspect(served)} base units, more than
    the #{intended} being ordered.

    Nothing was signed and no allowance was granted. The approve is sized by the
    permit, so a permit larger than the intended origin amount would widen the
    allowance past what this run is worth. Re-quote, or raise --amount if the
    larger figure is really what you meant to send.
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

  defp permit2_plan(_pull, pinned, _origin) when pinned in [nil, ""],
    do: {:error, :unpinned_permit2_spender}

  defp permit2_plan(pull, pinned, origin) do
    message = section(pull, "message")
    permitted = section(message, "permitted")

    with {:ok, spender} <- match_spender(message["spender"], pinned),
         :ok <- match_chain(section(pull, "domain")["chainId"], origin.chain_id),
         :ok <- match_token(permitted["token"], origin.token),
         {:ok, amount} <- bounded_amount(permitted["amount"], origin.amount) do
      {:ok,
       {:permit2,
        %{
          spender: spender,
          chain_id: origin.chain_id,
          token: origin.token,
          amount: amount
        }}}
    end
  end

  defp match_spender(served, pinned) do
    with {:ok, served_addr} <- address(served, :served),
         {:ok, pinned_addr} <- address(pinned, :pinned) do
      compare(served_addr, pinned_addr, served)
    end
  end

  defp compare(addr, addr, served), do: {:ok, served}

  defp compare(served_addr, pinned_addr, _served),
    do: {:error, {:pull_spender_mismatch, "0x" <> served_addr, "0x" <> pinned_addr}}

  # The permit is signed for one chain and one token; the allowance is granted on
  # the operator's origin leg. If those differ, the approve is for a leg nobody
  # asked about.
  defp match_chain(served, intended) do
    case to_uint(served) do
      ^intended -> :ok
      _ -> {:error, {:pull_chain_mismatch, served, intended}}
    end
  end

  defp match_token(served, intended) do
    case addr_match?(served, intended) do
      true -> :ok
      false -> {:error, {:pull_token_mismatch, served, intended}}
    end
  end

  # The approve is sized by the permit, so the permit must not be bigger than the
  # transfer it belongs to. Same bound the payments-side `validate_permit2_pull/2`
  # applies to the signature, applied here BEFORE the allowance rather than after.
  defp bounded_amount(served, intended) do
    case {to_uint(served), to_uint(intended)} do
      {value, limit} when is_integer(value) and is_integer(limit) and value <= limit ->
        {:ok, value}

      _ ->
        {:error, {:pull_amount_unbounded, served, intended}}
    end
  end

  # The served envelope is remote JSON: any level of it may be absent or the wrong
  # shape, and a malformed one must reach this module's own refusal rather than
  # raise out of an Access call.
  defp section(map, key) when is_map(map) do
    case Map.get(map, key) do
      nested when is_map(nested) -> nested
      _ -> %{}
    end
  end

  defp section(_map, _key), do: %{}

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

  defp addr_match?(a, b) when is_binary(a) and is_binary(b) do
    normalized = EIP712.normalize_address(a)
    Regex.match?(@address, normalized) and normalized == EIP712.normalize_address(b)
  end

  defp addr_match?(_a, _b), do: false

  defp to_uint(value) when is_integer(value) and value >= 0, do: value

  defp to_uint(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp to_uint(_value), do: nil

  # A rehearsal goes through the same read the batching path does, so there is one
  # threshold and `--dry-run` cannot promise a different run.
  defp ensure(true, provider, permit, owner) do
    with {:ok, status} <- allowance_status({:permit2, permit}, provider, owner) do
      {:ok, rehearsed(status)}
    end
  end

  defp ensure(false, provider, permit, owner) do
    with {:ok, result} <-
           Permit2Approver.ensure_allowance(provider, permit.chain_id, permit.token, owner,
             min_allowance: permit.amount,
             amount: permit.amount
           ) do
      {:ok, granted(result, permit.amount)}
    end
  end

  defp rehearsed(:standing), do: :standing
  defp rehearsed({:short, permit}), do: {:would_approve, permit.amount}

  defp granted(:sufficient, _amount), do: :standing
  defp granted({:approved, hash}, amount), do: {:approved, amount, hash}
end
