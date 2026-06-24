defmodule Raxol.Payments.Protocols.Xochi do
  @moduledoc """
  Xochi private execution protocol.

  Xochi is the default agent-facing protocol for cross-chain transfers.
  It routes intents through the Xochi dark pool where Riddler (and other
  solvers) compete to fill them. This is the cash-positive path with
  tier-based fees.

  Unlike x402/MPP, Xochi is not a 402-triggered protocol. It uses an
  explicit quote -> sign -> execute -> poll flow.

  ## Usage

      config = %{base_url: "https://riddler.example.com", auth_token: "..."}
      wallet = MyWallet

      {:ok, quote} = Xochi.quote(config, %QuoteRequest{...})
      {:ok, exec} = Xochi.execute(config, quote, wallet)
      {:ok, status} = Xochi.poll_status(config, exec.intent_id)

  ## Fee Tiers

  | Tier           | Score | Fee   |
  |----------------|-------|-------|
  | Standard       | 0-24  | 0.30% |
  | Trusted        | 25-49 | 0.25% |
  | Verified       | 50-74 | 0.20% |
  | Premium        | 75-99 | 0.15% |
  | Institutional  | 100+  | 0.10% |
  """

  @behaviour Raxol.Payments.Protocol

  alias Raxol.Payments.Poll
  alias Raxol.Payments.Xochi.Client
  alias Raxol.Payments.Xochi.Schemas.{QuoteRequest, QuoteResponse, ExecuteRequest, IntentStatus}

  # -- Protocol behaviour (stubs -- Xochi is not a 402 protocol) --

  @impl true
  @spec name() :: String.t()
  def name, do: "Xochi"

  @impl true
  @spec detect?(integer(), [{String.t(), String.t()}]) :: boolean()
  def detect?(_status, _headers), do: false

  @impl true
  @spec parse_challenge([{String.t(), String.t()}]) :: {:error, :not_a_402_protocol}
  def parse_challenge(_headers), do: {:error, :not_a_402_protocol}

  @impl true
  @spec build_payment(map(), module()) :: {:error, :not_a_402_protocol}
  def build_payment(_challenge, _wallet), do: {:error, :not_a_402_protocol}

  @impl true
  @spec parse_receipt([{String.t(), String.t()}]) :: {:error, :not_a_402_protocol}
  def parse_receipt(_headers), do: {:error, :not_a_402_protocol}

  @impl true
  @spec amount(map()) :: Decimal.t()
  def amount(%{to_amount: amt}) when is_binary(amt), do: Decimal.new(amt)
  def amount(%{xochi_fee: fee}) when is_binary(fee), do: Decimal.new(fee)
  def amount(_challenge), do: Decimal.new(0)

  # -- Direct API --

  @doc """
  Request a cross-chain intent quote from Xochi.
  """
  @spec get_quote(Client.config(), QuoteRequest.t()) ::
          {:ok, QuoteResponse.t()} | {:error, term()}
  def get_quote(config, %QuoteRequest{} = request) do
    Client.get_quote(config, request)
  end

  @doc """
  Sign and execute an intent from a quote.

  Signs the EIP-712 typed data from the quote response using the wallet,
  then submits the signed intent for execution.
  """
  @spec execute(Client.config(), QuoteResponse.t(), module()) ::
          {:ok, Raxol.Payments.Xochi.Schemas.ExecuteResponse.t()} | {:error, term()}
  def execute(config, %QuoteResponse{} = quote_resp, wallet) do
    with :ok <- validate_quote(quote_resp),
         {:ok, signature} <- sign_quote(quote_resp, wallet) do
      request = %ExecuteRequest{
        intent_id: quote_resp.intent_id,
        quote_id: quote_resp.quote_id,
        signature: signature,
        nonce: signed_nonce(quote_resp)
      }

      Client.execute(config, request)
    end
  end

  @doc """
  Poll intent status until terminal (completed/failed/expired) or timeout.

  Fast-polls inside the settlement budget window, then backs off. See
  `Raxol.Payments.Poll` for the timing options (`:budget_ms`,
  `:fast_interval_ms`, `:slow_interval_ms`, `:timeout_ms`).
  """
  @spec poll_status(Client.config(), String.t(), keyword()) ::
          {:ok, IntentStatus.t()} | {:error, term()}
  def poll_status(config, intent_id, opts \\ []) do
    case poll_status_timed(config, intent_id, opts) do
      {:ok, status, _elapsed_ms} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Like `poll_status/3` but also returns the elapsed milliseconds to the terminal
  status, so the caller can report whether settlement landed within budget.
  """
  @spec poll_status_timed(Client.config(), String.t(), keyword()) ::
          {:ok, IntentStatus.t(), non_neg_integer()} | {:error, term()}
  def poll_status_timed(config, intent_id, opts \\ []) do
    Poll.run(
      fn -> Client.get_status(config, intent_id) end,
      &IntentStatus.terminal?/1,
      opts
    )
  end

  @doc """
  Full transfer flow: quote -> sign -> execute -> poll.

  Convenience function that runs the complete Xochi intent lifecycle.
  Returns the final terminal status.
  """
  @spec transfer(Client.config(), QuoteRequest.t(), module(), keyword()) ::
          {:ok, IntentStatus.t()} | {:error, term()}
  def transfer(config, %QuoteRequest{} = request, wallet, opts \\ []) do
    with {:ok, quote_resp} <- get_quote(config, request),
         {:ok, exec_resp} <- execute(config, quote_resp, wallet) do
      poll_status(config, exec_resp.intent_id, opts)
    end
  end

  # -- Private --

  defp validate_quote(%QuoteResponse{can_solve: false, error: err}) do
    {:error, {:cannot_solve, err || "no solver available"}}
  end

  defp validate_quote(%QuoteResponse{can_solve: true}), do: :ok

  defp sign_quote(%QuoteResponse{eip712_data: nil}, _wallet) do
    {:error, :no_eip712_data}
  end

  defp sign_quote(%QuoteResponse{eip712_data: eip712}, wallet) do
    domain = eip712_domain(eip712)
    types = eip712_types(eip712)
    message = eip712_message(eip712)

    case wallet.sign_typed_data(domain, types, message) do
      {:ok, sig_bytes} ->
        {:ok, "0x" <> Base.encode16(sig_bytes, case: :lower)}

      {:error, reason} ->
        {:error, {:sign_failed, reason}}
    end
  end

  # The execute nonce must equal the nonce in the typed data the wallet signed,
  # so the solver recovers the same digest. The Xochi quote bakes a fixed nonce
  # into the eip712 message (0 in the canonical XochiIntent type); echo that
  # rather than minting a fresh value.
  defp signed_nonce(%QuoteResponse{eip712_data: %{"message" => %{"nonce" => nonce}}})
       when is_integer(nonce),
       do: nonce

  defp signed_nonce(_quote_resp), do: 0

  # Build the domain from exactly the keys the worker served. `verifyingContract`
  # is only included when present: the canonical XochiIntent domain omits it, so
  # adding a nil key would hash a 4-field EIP712Domain against the worker's
  # 3-field one and the signature would not recover.
  defp eip712_domain(eip712) do
    d = eip712["domain"] || %{}

    %{name: d["name"], version: d["version"], chainId: d["chainId"]}
    |> maybe_put_verifying_contract(d["verifyingContract"])
  end

  defp maybe_put_verifying_contract(domain, nil), do: domain
  defp maybe_put_verifying_contract(domain, vc), do: Map.put(domain, :verifyingContract, vc)

  defp eip712_types(eip712) do
    (eip712["types"] || %{})
    |> Map.drop(["EIP712Domain"])
    |> Enum.into(%{}, fn {name, fields} ->
      {name, Enum.map(fields, fn f -> {f["name"], f["type"]} end)}
    end)
  end

  defp eip712_message(eip712) do
    eip712["message"] || %{}
  end
end
