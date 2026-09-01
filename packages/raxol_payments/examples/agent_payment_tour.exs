# Agent Payment Tour: the whole payable surface, in one run
#
# The other two examples each walk ONE rail end to end. This one answers the
# prior question: what can an agent pay with at all, and who decides which rail
# a given request takes?
#
# Four sections:
#
#   1. The tool surface. Every payment Action an agent can call, read off the
#      Actions themselves rather than a hand-kept list, plus the LLM tool
#      definition for one of them so you can see what the model actually sees.
#   2. Protocol routing. `Router.select/1` over a table of request shapes, so
#      the rule that picks x402 vs Xochi vs Relay is visible as a matrix.
#   3. An x402 payment, end to end and in process: 402 challenge -> EIP-712
#      signature -> 200 with a receipt.
#   4. The spend gate refusing the same call when it breaks the policy.
#
# Runs fully offline and spends nothing. Section 3 mounts the real
# `Raxol.Payments.EchoServer` as a Req plug instead of over a socket, so this
# needs no second terminal -- the challenge, the signing and the verification
# are the same code the two-terminal `preflight.exs` rehearsal drives.
#
# Usage (from packages/raxol_payments/):
#
#   MIX_ENV=test mix run examples/agent_payment_tour.exs

Logger.configure(level: :warning)

defmodule AgentPaymentTour do
  alias Raxol.Payments.{EchoServer, Ledger, Req.AutoPay, Router, SpendingPolicy}

  @base 8453
  @tron 728_126_428

  # The echo server fills these itself when it runs over a socket; mounted as a
  # bare plug its `init/1` passes opts straight through, so state them here.
  # 10_000 atomic units of a 6-decimal asset is one cent.
  @echo_opts [
    amount: 10_000,
    pay_to: "0x" <> String.duplicate("ab", 20),
    asset: "0x" <> String.duplicate("cd", 20),
    network: "eip155:#{@base}"
  ]

  def run do
    tool_surface()
    routing_matrix()

    wallet = ephemeral_wallet()
    {:ok, ledger} = Ledger.start_link(table_name: :tour_ledger)

    autopay(wallet, ledger)
    spend_gate(wallet, ledger)

    Process.sleep(20)
    :ok
  end

  # -- 1. what the agent can call --

  # Derived from the loaded modules, not a hand-kept list: an Action added to
  # the package shows up here without this example being touched.
  defp tool_surface do
    actions = payment_actions()

    header("1. payment tool surface", "#{length(actions)} Actions on the agent")

    Enum.each(actions, fn {_name, meta} ->
      IO.puts("  #{pad(meta.name, 34)}#{sensitivity(meta)}  #{meta.description}")
    end)

    IO.puts("""

      A sensitive Action moves funds. On the LLM tool-call path those are denied
      outright unless the agent opts in with a :tool_authorizer, so a model that
      hallucinates a transfer cannot execute one. Reads need no such gate.
    """)

    {_, quoted} = Enum.find(actions, fn {name, _} -> name == "payment_get_quote" end)
    IO.puts("  what the model sees for #{quoted.name}:\n")

    Raxol.Payments.Actions.Payments.GetQuote.to_tool_definition()
    |> Jason.encode!(pretty: true)
    |> indent("    ")
    |> IO.puts()
  end

  defp payment_actions do
    {:ok, modules} = :application.get_key(:raxol_payments, :modules)

    modules
    |> Enum.filter(&action?/1)
    |> Enum.map(fn module ->
      meta = module.__action_meta__()
      {meta.name, meta}
    end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  defp action?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__action_meta__, 0)
  end

  defp sensitivity(%{sensitive: true}), do: "[moves funds]"
  defp sensitivity(_), do: "[read only] "

  # -- 2. which rail a request takes --

  defp routing_matrix do
    header("2. protocol routing", "Router.select/1 decides; no network involved")

    rows = [
      {"same-chain API call", [cross_chain: false]},
      {"cross-chain transfer", [cross_chain: true]},
      {"privacy: stealth", [privacy: :stealth]},
      {"privacy: shielded", [privacy: :shielded]},
      {"leg into Tron", [to_chain_id: @tron, from_chain_id: @base]},
      {"stealth INTO Tron", [privacy: :stealth, to_chain_id: @tron]},
      {"operator forces riddler", [cross_chain: true, protocol: :riddler]}
    ]

    Enum.each(rows, fn {label, opts} ->
      IO.puts("  #{pad(label, 26)}-> #{Router.select(opts)}")
    end)

    IO.puts("""

      Read the last three together. A Tron leg wins over privacy, because the
      Relay rail is public-only -- so "stealth INTO Tron" routes to :relay and
      is then refused at the Action rather than quietly settling in public.
      An explicit :protocol overrides the lot; Riddler is B2B and cash-negative,
      which is why nothing auto-selects it.
    """)
  end

  # -- 3. paying an x402 challenge --

  defp autopay(wallet, ledger) do
    header("3. x402 auto-pay", "402 -> sign -> 200, all in process")

    policy = policy()

    IO.puts("  wallet:   #{wallet.address()}")
    IO.puts("  policy:   per_request=#{policy.per_request_max} USDC")
    IO.puts("  charge:   0.01 USDC (10000 atomic, 6 decimals)\n")

    case Req.get(request("https://echo.x402/anything", wallet, ledger, policy)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        receipt = body["receipt"]
        IO.puts("  paid. settled_by=#{receipt["settledBy"]} tx=#{receipt["transactionHash"]}")

      {:ok, %Req.Response{status: status, body: body}} ->
        IO.puts("  unexpected #{status}: #{inspect(body)}")
        System.halt(1)

      {:error, reason} ->
        IO.puts("  failed: #{inspect(reason)}")
        System.halt(1)
    end

    totals = Ledger.get_totals(ledger, :tour, policy)
    IO.puts("  ledger:   session=#{totals.session} lifetime=#{totals.lifetime} USDC")
  end

  # -- 4. the same call, over the cap --

  defp spend_gate(wallet, ledger) do
    header("4. the spend gate", "same rail, a policy that will not have it")

    # One cent charge against a policy that permits a tenth of that.
    policy = %{policy() | per_request_max: Decimal.new("0.001")}

    IO.puts("  policy:   per_request=#{policy.per_request_max} USDC")
    IO.puts("  charge:   0.01 USDC\n")

    # On a denial AutoPay leaves the upstream 402 in place and replaces the body
    # with the gate's own verdict, keyed by atom.
    case Req.get(request("https://echo.x402/anything", wallet, ledger, policy)) do
      {:ok, %Req.Response{status: 402, body: %{error: reason} = body}} ->
        IO.puts("  denied [#{reason}] on the #{body[:limit]} limit")
        IO.puts("  the upstream 402 stands and no signature was released")

      {:ok, %Req.Response{status: 200}} ->
        IO.puts("  ERROR: an over-limit payment was signed and accepted")
        System.halt(1)

      {:ok, %Req.Response{status: status, body: body}} ->
        IO.puts("  ERROR: unexpected #{status}: #{inspect(body)}")
        System.halt(1)

      {:error, reason} ->
        IO.puts("  denied at the client: #{inspect(reason)}")
    end

    IO.puts("""

      The gate reserves against the Ledger BEFORE the wallet is asked to sign,
      so a refusal costs a round trip and never a signature.
    """)
  end

  defp request(url, wallet, ledger, policy) do
    Req.new(url: url, retry: false, plug: {EchoServer, @echo_opts})
    |> AutoPay.attach(
      wallet: wallet,
      ledger: ledger,
      policy: policy,
      agent_id: :tour
    )
  end

  defp policy do
    %SpendingPolicy{
      per_request_max: Decimal.new("1.00"),
      session_max: Decimal.new("10.00"),
      lifetime_max: Decimal.new("100.00"),
      session_window_ms: 3_600_000,
      currency: "USDC",
      approved_domains: ["echo.x402"]
    }
  end

  defp ephemeral_wallet do
    key = "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    System.put_env("TOUR_WALLET_KEY", key)

    defmodule TourWallet do
      use Raxol.Payments.Wallets.Env, env_var: "TOUR_WALLET_KEY"
    end

    TourWallet
  end

  # -- output helpers --

  defp header(title, subtitle) do
    IO.puts("\n== #{title} ==")
    IO.puts("   #{subtitle}\n")
  end

  defp pad(text, width), do: String.pad_trailing(text, width)

  defp indent(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &(prefix <> &1))
  end
end

AgentPaymentTour.run()
