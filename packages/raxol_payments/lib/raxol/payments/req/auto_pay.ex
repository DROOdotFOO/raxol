defmodule Raxol.Payments.Req.AutoPay do
  @moduledoc """
  Req plugin that transparently handles HTTP 402 Payment Required responses.

  Intercepts 402 responses, detects the payment protocol (x402 or MPP),
  checks spending budget, signs a payment, and retries the request with
  payment credentials attached. Retries at most once per request to
  prevent infinite loops.

  ## Usage

      req =
        Req.new(url: "https://api.example.com/data")
        |> Raxol.Payments.Req.AutoPay.attach(
          wallet: Raxol.Payments.Wallets.Env,
          protocols: [:x402, :mpp],
          ledger: ledger_pid,
          policy: SpendingPolicy.dev(),
          agent_id: :my_agent
        )

      {:ok, response} = Req.get(req)

  ## Options

  - `:wallet` (required) -- module implementing `Raxol.Payments.Wallet`
  - `:protocols` -- list of protocol atoms, default `[:x402, :mpp]`
  - `:ledger` -- Ledger server for budget tracking (optional)
  - `:policy` -- `SpendingPolicy` struct; when set, `approved_domains` and
    `require_confirmation_above` are enforced against the request URL host
    before the wallet is asked to sign
  - `:agent_id` -- identifier for ledger tracking (required if ledger given)
  - `:on_confirm` -- 2-arity function `(amount, domain) -> :approve | :deny`
    called when `policy.require_confirmation_above` is exceeded. Runs
    synchronously inside the Req response step. Absent or non-`:approve`
    return denies the payment.
  """

  alias Raxol.Payments.{Ledger, PolicyGate, Protocol, SpendingPolicy}

  @default_protocols [:x402, :mpp]

  @doc """
  Attach the auto-pay plugin to a Req request.
  """
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = req, opts) do
    Req.Request.append_response_steps(req, auto_pay: &handle_response(&1, opts))
  end

  @spec handle_response({Req.Request.t(), Req.Response.t()}, keyword()) ::
          {Req.Request.t(), Req.Response.t()}
  defp handle_response({request, %Req.Response{status: 402} = response}, opts) do
    wallet = Keyword.fetch!(opts, :wallet)
    protocols = Keyword.get(opts, :protocols, @default_protocols)
    headers = Raxol.Payments.Headers.flatten(response.headers)

    with {:ok, protocol_mod, challenge} <- detect_and_parse(protocols, headers),
         :ok <- try_spend_budget(protocol_mod, challenge, request, opts),
         {:ok, payment_headers} <- protocol_mod.build_payment(challenge, wallet) do
      # Build retry request: add payment headers and strip the auto_pay step
      # to prevent infinite loops if the server returns 402 again.
      retry_request =
        request
        |> add_payment_headers(payment_headers)
        |> remove_auto_pay_step()

      case Req.Request.run(retry_request) do
        {_req, %Req.Response{status: status} = paid_response}
        when status in 200..299 ->
          {request, paid_response}

        {_req, %Req.Response{} = failed_response} ->
          {request, failed_response}

        {:error, reason} ->
          {request,
           %{
             response
             | body: %{
                 error: :payment_retry_failed,
                 reason: sanitize_error(reason)
               }
           }}
      end
    else
      error -> handle_failure(error, request, response)
    end
  end

  defp handle_response(req_response, _opts), do: req_response

  defp handle_failure({:error, :no_matching_protocol}, request, response),
    do: {request, response}

  defp handle_failure(
         {:error, {:over_budget, limit_type, _amount}},
         request,
         response
       ),
       do:
         {request,
          %{response | body: %{error: :budget_exceeded, limit: limit_type}}}

  defp handle_failure(
         {:error, {:gate_denied, {:domain_not_approved, domain}}},
         request,
         response
       ),
       do:
         {request,
          %{response | body: %{error: :domain_not_approved, domain: domain}}}

  defp handle_failure(
         {:error, {:gate_denied, {:requires_confirmation, amount, domain}}},
         request,
         response
       ) do
    body = %{error: :requires_confirmation, amount: amount, domain: domain}
    {request, %{response | body: body}}
  end

  defp handle_failure(
         {:error, {:gate_denied, :missing_host}},
         request,
         response
       ),
       do: {request, %{response | body: %{error: :missing_host}}}

  defp handle_failure({:error, reason}, request, response) do
    body = %{error: :payment_failed, reason: sanitize_error(reason)}
    {request, %{response | body: body}}
  end

  @spec detect_and_parse([atom()], Raxol.Payments.Headers.headers()) ::
          {:ok, module(), map()} | {:error, :no_matching_protocol}
  defp detect_and_parse(protocols, headers) do
    Enum.find_value(protocols, {:error, :no_matching_protocol}, fn proto_atom ->
      mod = Protocol.resolve(proto_atom)

      if mod.detect?(402, headers) do
        case mod.parse_challenge(headers) do
          {:ok, challenge} -> {:ok, mod, challenge}
          {:error, _} -> nil
        end
      end
    end)
  end

  @spec try_spend_budget(module(), map(), Req.Request.t(), keyword()) ::
          :ok | {:error, term()}
  defp try_spend_budget(protocol_mod, challenge, request, opts) do
    amount = protocol_mod.amount(challenge)
    host = request_host(request)
    policy = Keyword.get(opts, :policy)

    with :ok <- enforce_policy_gate(policy, amount, host, opts) do
      enforce_budget(protocol_mod, amount, host, opts)
    end
  end

  defp enforce_policy_gate(nil, _amount, _host, _opts), do: :ok

  defp enforce_policy_gate(%SpendingPolicy{} = _policy, _amount, host, _opts)
       when host in [nil, ""],
       do: {:error, {:gate_denied, :missing_host}}

  defp enforce_policy_gate(%SpendingPolicy{} = policy, amount, host, opts) do
    case PolicyGate.evaluate(policy, amount, host,
           on_confirm: Keyword.get(opts, :on_confirm)
         ) do
      :ok -> :ok
      {:deny, reason} -> {:error, {:gate_denied, reason}}
    end
  end

  defp enforce_budget(protocol_mod, amount, host, opts) do
    do_enforce_budget(
      Keyword.get(opts, :policy),
      Keyword.get(opts, :ledger),
      protocol_mod,
      amount,
      host,
      opts
    )
  end

  defp do_enforce_budget(nil, _ledger, _proto, _amount, _host, _opts), do: :ok
  defp do_enforce_budget(_policy, nil, _proto, _amount, _host, _opts), do: :ok

  defp do_enforce_budget(
         %SpendingPolicy{} = policy,
         ledger,
         protocol_mod,
         amount,
         host,
         opts
       ) do
    agent_id = Keyword.get(opts, :agent_id, :unknown)
    metadata = %{protocol: protocol_mod.name(), domain: host}

    case Ledger.try_spend(ledger, agent_id, amount, policy, metadata) do
      :ok -> :ok
      {:over_limit, limit_type} -> {:error, {:over_budget, limit_type, amount}}
    end
  end

  defp request_host(%Req.Request{url: %URI{host: host}})
       when is_binary(host) and host != "",
       do: host

  defp request_host(%Req.Request{url: url}) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp request_host(_), do: nil

  defp add_payment_headers(request, headers) do
    Enum.reduce(headers, request, fn {key, value}, req ->
      Req.Request.put_header(req, key, value)
    end)
  end

  # Strip internal details from error reasons before including in response bodies.
  # Prevents leaking API URLs, internal state, or cryptographic details.
  defp sanitize_error({:sign_failed, _}), do: :sign_failed
  defp sanitize_error({:op_failed, _code, _output}), do: :wallet_unavailable
  defp sanitize_error({:request_failed, _}), do: :upstream_error
  defp sanitize_error(reason) when is_atom(reason), do: reason
  defp sanitize_error(_), do: :internal_error

  defp remove_auto_pay_step(request) do
    steps =
      request.response_steps
      |> Enum.reject(fn {name, _fun} -> name == :auto_pay end)

    %{request | response_steps: steps}
  end
end
