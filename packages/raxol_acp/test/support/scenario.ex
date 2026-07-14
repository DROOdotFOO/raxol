defmodule Raxol.ACP.Test.Scenario do
  @moduledoc """
  A pipe-friendly harness for ACP cross-chain settlement journeys, over
  `Raxol.ACP.TestSupport.FakeXochi`. Drives the real client -> protocol ->
  offering -> `JobSession` -> `Settler` path with no network and no funds.

  Mirrors the shape of `Raxol.MCP.Test`: each step threads a `%Scenario{}` and
  the `assert_*` steps return it, so a whole user journey reads as one pipe.

      import Raxol.ACP.Test.Scenario

      new(wallet: BuyerWallet)
      |> order("USDC", from: 8453, to: 10, amount: "1100000")
      |> settle()
      |> assert_delivered()

  Failure and state assertions compose the same way:

      new(wallet: BuyerWallet, unavailable_origins: [4663])
      |> order("USDC", from: 4663, to: 8453)
      |> assert_order_rejected()

      new(wallet: BuyerWallet, inventory: %{{10, usdc} => 1_100_000})
      |> order("USDC", from: 8453, to: 10, amount: "1100000")
      |> settle()
      |> assert_delivered()
      |> assert_inventory(10, "USDC", 0)

  ## `new/1` options

  - `:wallet` (required) -- the buyer's `Raxol.Payments.Wallets.Env` module; it
    signs the EIP-712 intent + origin pull. The caller sets its key env var.
  - `:inventory`, `:unavailable_origins`, `:solver`, `:floor` -- forwarded to
    `FakeXochi.start_link/1` (`:solver` is the origin-pull recipient the quote serves).
  - `:solver_allowlist` -- pin the origin-pull solver (sets
    `:pull_solver_allowlist` + `:pull_require_solver_pin`, restored on exit), as the
    live gate does. A served `:solver` outside the list is rejected before signing.
  - `:destination_caps`, `:closed_origins` -- set the offering's liquidity gate
    (`:raxol_acp` app env, restored on exit): a per-`{dst_chain, dst_token}` max
    order size and the src chains to reject before escrow.
  - `:budget` -- USDC budget for the job escrow (default `"0.25"`).

  `new/1` starts the fake, registers the offering, points the settler at the fake,
  resets the capability cache, and registers `on_exit` cleanup -- so it is
  self-contained inside a test.
  """

  import ExUnit.Assertions

  alias Raxol.ACP.{AssetToken, Chain, JobSession}
  alias Raxol.ACP.Offering.Registry, as: OfferingRegistry
  alias Raxol.ACP.ProviderAdapter
  alias Raxol.ACP.TestSupport.FakeXochi
  alias Raxol.ACP.Xochi.TransferOffering
  alias Raxol.Payments.Assets
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Capabilities
  alias Raxol.Payments.Xochi.Schemas.QuoteRequest

  @enforce_keys [:fake, :cfg, :wallet, :budget]
  defstruct [
    :fake,
    :cfg,
    :wallet,
    :budget,
    :request,
    :bundle,
    :requirement,
    :session,
    :provider,
    :deliverable,
    :error
  ]

  @type t :: %__MODULE__{}

  @fake_opts [:inventory, :unavailable_origins, :solver, :floor]

  @doc "Start a scenario. See the module docs for options."
  @spec new(keyword()) :: t()
  def new(opts) do
    wallet = Keyword.fetch!(opts, :wallet)
    {:ok, fake} = FakeXochi.start_link(Keyword.take(opts, @fake_opts))
    cfg = FakeXochi.config(fake)

    Capabilities.reset()
    OfferingRegistry.clear()
    {:ok, _spec} = TransferOffering.register()

    Application.put_env(:raxol_acp, :xochi_transfer_settler,
      xochi_config: cfg,
      poll_timeout_ms: 5_000,
      poll_interval_ms: 5
    )

    restore_pin = pin_solver(Keyword.get(opts, :solver_allowlist))
    restore_caps = put_gate_env(:destination_caps, opts)
    restore_origins = put_gate_env(:closed_origins, opts)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:raxol_acp, :xochi_transfer_settler)
      Capabilities.reset()
      restore_pin.()
      restore_caps.()
      restore_origins.()
    end)

    %__MODULE__{fake: fake, cfg: cfg, wallet: wallet, budget: Keyword.get(opts, :budget, "0.25")}
  end

  @doc """
  The buyer quotes and signs the intent, then orders it through the ACP job
  lifecycle up to `:funded`. On any failure (unavailable corridor, rejected job)
  the scenario carries an `:error` and later steps short-circuit.

  Options: `:from` and `:to` chain ids (required), `:amount` (atomic string,
  default `"1100000"`), `:settlement` (default `"public"`).
  """
  @spec order(t(), String.t(), keyword()) :: t()
  def order(%__MODULE__{error: nil} = s, token, opts) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.fetch!(opts, :to)
    amount = Keyword.get(opts, :amount, "1100000")

    {:ok, src} = Assets.address(from, leg_token(from, token))
    {:ok, dst} = Assets.address(to, leg_token(to, token))

    request = %QuoteRequest{
      wallet: s.wallet.address(),
      from_chain_id: from,
      to_chain_id: to,
      from_token: src,
      to_token: dst,
      from_amount: amount,
      settlement_preference: Keyword.get(opts, :settlement, "public")
    }

    case Xochi.quote_and_sign(s.cfg, request, s.wallet) do
      {:ok, bundle} ->
        place_order(%{s | request: request, bundle: bundle}, from, to, src, dst, amount)

      {:error, reason} ->
        %{s | error: {:quote_failed, reason}}
    end
  end

  def order(%__MODULE__{} = s, _token, _opts), do: s

  @doc "The seller settles the funded job. Short-circuits if an earlier step errored."
  @spec settle(t()) :: t()
  def settle(%__MODULE__{error: nil, provider: provider, requirement: req} = s)
      when not is_nil(provider) do
    case JobSession.Provider.deliver(provider, req) do
      {:ok, %{status: :submitted, deliverable: deliverable}} ->
        %{s | deliverable: deliverable}

      other ->
        %{s | error: {:deliver_failed, other}}
    end
  end

  def settle(%__MODULE__{} = s), do: s

  @doc "Assert the job settled with a real destination settlement tx. Returns the scenario."
  @spec assert_delivered(t()) :: t()
  def assert_delivered(%__MODULE__{deliverable: d} = s) when is_map(d) do
    assert d["status"] in ["completed", "settled"],
           "expected a completed settlement, got #{inspect(d)}"

    assert d["settlement_tx_hash"] =~ ~r/^0x[0-9a-fA-F]{64}$/,
           "expected a real settlement tx hash, got #{inspect(d)}"

    assert d["intent_id"] == s.bundle.intent_id,
           "deliverable intent id #{inspect(d["intent_id"])} != ordered #{inspect(s.bundle.intent_id)}"

    s
  end

  def assert_delivered(%__MODULE__{error: error}) do
    flunk("expected a delivered settlement, got error: #{inspect(error)}")
  end

  @doc "Assert the order never reached settlement (no funds moved). Returns the scenario."
  @spec assert_order_rejected(t()) :: t()
  def assert_order_rejected(%__MODULE__{error: nil, deliverable: d}) when is_map(d) do
    flunk("expected the order to be rejected, but it settled: #{inspect(d)}")
  end

  def assert_order_rejected(%__MODULE__{error: nil}) do
    flunk("expected the order to be rejected, but no error was recorded")
  end

  def assert_order_rejected(%__MODULE__{} = s), do: s

  @doc "Assert remaining destination inventory for a `{chain, token}`. Returns the scenario."
  @spec assert_inventory(t(), pos_integer(), String.t(), non_neg_integer() | :infinity) :: t()
  def assert_inventory(%__MODULE__{fake: fake} = s, chain, token, expected) do
    {:ok, address} = Assets.address(chain, leg_token(chain, token))
    assert FakeXochi.inventory(fake, chain, address) == expected
    s
  end

  @doc "The recorded error, for a custom assertion."
  @spec error(t()) :: term() | nil
  def error(%__MODULE__{error: error}), do: error

  @doc "The delivered map, once settled."
  @spec deliverable(t()) :: map() | nil
  def deliverable(%__MODULE__{deliverable: deliverable}), do: deliverable

  @doc "The underlying `FakeXochi` server pid, for direct inspection."
  @spec fake(t()) :: pid()
  def fake(%__MODULE__{fake: fake}), do: fake

  @doc "The Xochi client config wired to this scenario's fake, for a direct call."
  @spec cfg(t()) :: map()
  def cfg(%__MODULE__{cfg: cfg}), do: cfg

  # -- Internal --

  defp place_order(s, from, to, src, dst, amount) do
    requirement = build_requirement(from, to, src, dst, amount, s.bundle)
    {chain_id, job_id, provider} = start_provider(s.wallet)
    budget = AssetToken.usdc(Decimal.new(s.budget), chain_id)

    case JobSession.Provider.accept_request(provider, requirement, budget) do
      {:ok, %{status: :budget_set}} ->
        {:ok, :funded} = JobSession.apply_event({chain_id, job_id}, :funded, %{})

        %{
          s
          | requirement: requirement,
            session: {chain_id, job_id},
            provider: provider
        }

      other ->
        %{s | requirement: requirement, error: {:accept_failed, other}}
    end
  end

  defp build_requirement(from, to, src, dst, amount, bundle) do
    %{
      "src_chain_id" => from,
      "dst_chain_id" => to,
      "src_token" => src,
      "dst_token" => dst,
      "amount_atomic" => amount,
      "signed_intent" => Map.new(bundle, fn {k, v} -> {to_string(k), v} end)
    }
  end

  defp start_provider(wallet) do
    chain_id = 8453
    job_id = "scenario-" <> Integer.to_string(System.unique_integer([:positive]))

    {:ok, _pid} =
      JobSession.Supervisor.start_session(chain_id: chain_id, job_id: job_id, role: :provider)

    provider =
      JobSession.Provider.new(
        session: {chain_id, job_id},
        handler: TransferOffering,
        adapter: ProviderAdapter.Mock.new(),
        chain_id: chain_id,
        acp_core_address: Chain.mainnet().acp_core_address,
        job_id: :erlang.phash2(job_id),
        buyer: wallet.address(),
        seller: wallet.address()
      )

    {chain_id, job_id, provider}
  end

  # Pin the origin-pull solver allowlist -- the live gate's anti-drain choke
  # point. Returns a thunk that restores the prior config on exit.
  defp pin_solver(nil), do: fn -> :ok end

  defp pin_solver(allowlist) do
    prior_list = Application.get_env(:raxol_payments, :pull_solver_allowlist)
    prior_pin = Application.get_env(:raxol_payments, :pull_require_solver_pin)

    Application.put_env(:raxol_payments, :pull_solver_allowlist, allowlist)
    Application.put_env(:raxol_payments, :pull_require_solver_pin, true)

    fn ->
      restore_env(:pull_solver_allowlist, prior_list)
      restore_env(:pull_require_solver_pin, prior_pin)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:raxol_payments, key)
  defp restore_env(key, value), do: Application.put_env(:raxol_payments, key, value)

  # Set a `:raxol_acp` gate env (`:destination_caps` / `:closed_origins`) from the
  # scenario opts, returning a thunk that restores the prior value on exit.
  defp put_gate_env(key, opts) do
    case Keyword.fetch(opts, key) do
      :error ->
        fn -> :ok end

      {:ok, value} ->
        prior = Application.get_env(:raxol_acp, key)
        Application.put_env(:raxol_acp, key, value)

        fn ->
          case prior do
            nil -> Application.delete_env(:raxol_acp, key)
            _ -> Application.put_env(:raxol_acp, key, prior)
          end
        end
    end
  end

  # Robinhood Chain (4663) carries USDG, not USDC/USDT, so a stablecoin corridor
  # touching it resolves the Robinhood leg to USDG (the cross-asset fill).
  defp leg_token(4663, token) do
    if String.upcase(token) in ["USDC", "USDT", "DAI", "USDG"], do: "USDG", else: token
  end

  defp leg_token(_chain, token), do: token
end
