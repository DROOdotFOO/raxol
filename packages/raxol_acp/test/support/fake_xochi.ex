defmodule Raxol.ACP.TestSupport.FakeXochi do
  @moduledoc """
  A stateful, behaviorally-faithful in-memory Xochi worker + Riddler solver, as a
  Req `:plug`. Drives the real `Raxol.Payments.Xochi.Client` /
  `Raxol.Payments.Protocols.Xochi` / `Raxol.ACP.Xochi.Settler` code paths against
  a modelled solver -- no network, no funds, deterministic.

  Unlike a per-test canned stub, this holds solver state and derives its answers,
  so tests exercise the emergent behaviors that only show up live:

  - **Destination inventory** per `{chain, token}`, decremented on each fill. When
    it runs short the solver quotes `can_solve: false` -- the inventory-exhaustion
    the launch mesh preflight surfaced (USDC concentrated on L1, thin on Arb).
  - **Unavailable origins** (e.g. Robinhood/USDG): a quote whose `from_chain_id` is
    listed answers HTTP 503 `"Solver temporarily unavailable"`, exactly as the live
    solver does for USDG-origin corridors (axol-io/Riddler#419). Destinations still
    fill -- the "into Robinhood works, out of it doesn't" asymmetry.
  - **Corridor floor** (`> 1 USDC` by default): a sub-floor amount quotes
    `amount_below_minimum`.

  A fillable quote carries a real EIP-712 `XochiIntent` and an ERC-3009 origin-pull
  authorization bound to the request (token, chain, value, signer) with the
  canonical Riddler solver as `to`, so the buyer's `quote_and_sign/3` genuinely
  signs and `validate_pull/3` genuinely runs. The intent settles instantly
  (`execute` marks it completed and returns a deterministic tx hash).

  ## Usage

      {:ok, fake} = FakeXochi.start_link(inventory: %{{10, usdc_addr} => 2_200_000})
      cfg = FakeXochi.config(fake)   # => %{base_url:, auth_token:, req_options: [plug:]}
      {:ok, bundle} = Xochi.quote_and_sign(cfg, request, BuyerWallet)
      FakeXochi.inventory(fake, 10, usdc_addr)   # remaining, for assertions

  ## Options

  - `:inventory` -- `%{{chain_id, token_address} => atomic_integer}`. A
    `{chain, token}` absent from the map is treated as unlimited, so tests that do
    not care about exhaustion need not seed anything.
  - `:unavailable_origins` -- chain ids whose outbound quotes answer 503.
  - `:floor` -- minimum `from_amount` (atomic), default `1_000_000` (1 USDC); the
    quote must be strictly above it.
  - `:solver` -- the origin-pull recipient, default the canonical Riddler solver.
  """

  # The canonical Riddler universal solver (HD index-0) the live gates pin.
  @canonical_solver "0x97D447561fDe10E959E782a29411D8F89586d80b"

  @doc "Start the fake solver. See module docs for options."
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts \\ []) do
    state = %{
      solver: Keyword.get(opts, :solver, @canonical_solver),
      floor: Keyword.get(opts, :floor, 1_000_000),
      unavailable_origins: MapSet.new(Keyword.get(opts, :unavailable_origins, [])),
      inventory: normalize_inventory(Keyword.get(opts, :inventory, %{})),
      intents: %{}
    }

    Agent.start_link(fn -> state end)
  end

  @doc "A Xochi client config wired to this fake via a Req `:plug`."
  @spec config(pid()) :: map()
  def config(server) do
    %{
      base_url: "https://fake.xochi.test",
      auth_token: "fake-test-token",
      req_options: [plug: plug(server)]
    }
  end

  @doc "The Req `:plug` function for this fake (for a hand-built config)."
  @spec plug(pid()) :: (Plug.Conn.t() -> Plug.Conn.t())
  def plug(server), do: fn conn -> handle(conn, server) end

  @doc """
  Remaining destination inventory for a `{chain, token}`, or `:infinity` when the
  leg was never seeded.
  """
  @spec inventory(pid(), pos_integer(), String.t()) :: non_neg_integer() | :infinity
  def inventory(server, chain, token) do
    key = {chain, downcase(token)}
    Agent.get(server, fn st -> Map.get(st.inventory, key, :infinity) end)
  end

  # -- Request routing --

  defp handle(conn, server) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    route(conn.method, conn.request_path, body, conn, server)
  end

  defp route("POST", "/api/intent/quote", raw, conn, server) do
    resp = Agent.get_and_update(server, fn st -> quote_intent(st, Jason.decode!(raw)) end)
    send_json(conn, resp.status, resp.body)
  end

  defp route("POST", "/api/intent/execute", raw, conn, server) do
    intent_id = Jason.decode!(raw)["intent_id"]
    resp = Agent.get_and_update(server, fn st -> execute_intent(st, intent_id) end)
    send_json(conn, resp.status, resp.body)
  end

  defp route("GET", path, _raw, conn, server) do
    case Regex.run(~r{^/api/intent/([^/]+)/status$}, path) do
      [_, intent_id] ->
        body = Agent.get(server, fn st -> status_body(st, intent_id) end)
        send_json(conn, 200, body)

      _ ->
        # Every other GET (e.g. GET /xochi/capabilities from the offering's
        # corridor gate) 404s, so Capabilities.get degrades to the Assets fallback.
        send_json(conn, 404, %{"error" => "not_found"})
    end
  end

  defp route(_method, _path, _raw, conn, _server) do
    send_json(conn, 404, %{"error" => "not_found"})
  end

  # -- Solver logic --

  # `Agent.get_and_update` fun: returns `{response, new_state}`.
  defp quote_intent(st, body) do
    from_chain = body["from_chain_id"]
    to_chain = body["to_chain_id"]
    from_token = body["from_token"]
    to_token = body["to_token"]
    amount = to_int(body["from_amount"])
    wallet = body["wallet"]

    cond do
      MapSet.member?(st.unavailable_origins, from_chain) ->
        {ok_resp(503, unavailable_body()), st}

      is_nil(amount) or amount <= st.floor ->
        {ok_resp(200, cannot_solve_body("amount_below_minimum")), st}

      not fillable?(st, to_chain, to_token, amount) ->
        {ok_resp(200, cannot_solve_body("insufficient_inventory")), st}

      true ->
        intent_id = "xi_" <> uid()
        quote_id = "xq_" <> uid()

        intent = %{
          to_chain: to_chain,
          to_token: downcase(to_token),
          to_amount: amount,
          status: "quoted"
        }

        st = put_in(st.intents[intent_id], intent)

        body =
          quote_body(intent_id, quote_id, %{
            from_chain: from_chain,
            from_token: from_token,
            amount: amount,
            wallet: wallet,
            solver: st.solver
          })

        {ok_resp(200, body), st}
    end
  end

  defp execute_intent(st, intent_id) do
    case Map.get(st.intents, intent_id) do
      nil ->
        {ok_resp(200, execute_body(intent_id, "failed", %{"error" => "unknown_intent"})), st}

      %{to_chain: chain, to_token: token, to_amount: amount} ->
        if fillable?(st, chain, token, amount) do
          st =
            st
            |> decrement(chain, token, amount)
            |> put_in([Access.key(:intents), intent_id, :status], "completed")

          body = execute_body(intent_id, "completed", %{"tx_hash" => tx_hash(intent_id)})
          {ok_resp(200, body), st}
        else
          st = put_in(st, [Access.key(:intents), intent_id, :status], "failed")
          body = execute_body(intent_id, "failed", %{"error" => "insufficient_inventory"})
          {ok_resp(200, body), st}
        end
    end
  end

  defp status_body(st, intent_id) do
    status = get_in(st.intents, [intent_id, :status]) || "failed"

    %{
      "intent_id" => intent_id,
      "status" => status,
      "terminal" => true,
      "tx_hash" => tx_hash(intent_id)
    }
  end

  # An unseeded leg is unlimited (`:infinity`); a seeded one gates on the balance.
  defp fillable?(st, chain, token, amount) do
    case Map.get(st.inventory, {chain, downcase(token)}, :infinity) do
      :infinity -> true
      n -> n >= amount
    end
  end

  defp decrement(st, chain, token, amount) do
    key = {chain, downcase(token)}

    case Map.get(st.inventory, key, :infinity) do
      :infinity -> st
      n -> put_in(st.inventory[key], n - amount)
    end
  end

  # -- Response bodies (snake_case, the canonical worker shape from_json reads) --

  defp quote_body(intent_id, quote_id, req) do
    %{
      "intent_id" => intent_id,
      "quote_id" => quote_id,
      "can_solve" => true,
      "payment_method" => "erc3009",
      "to_amount" => Integer.to_string(req.amount),
      "xochi_fee" => Integer.to_string(div(req.amount, 500)),
      "settlement_options" => [],
      "eip712" => xochi_intent_eip712(intent_id, req.from_chain),
      "pull_authorization" => erc3009_pull(intent_id, req)
    }
  end

  # The XochiIntent typed data. Mirrors the live worker's shape -- a salt-bearing
  # domain with no verifyingContract (the salt-domain the origin-pull signing fix
  # depends on) -- while staying minimal enough that any wallet signs it. The
  # intent id ties the signature to this quote.
  defp xochi_intent_eip712(intent_id, chain_id) do
    %{
      "domain" => %{
        "name" => "Xochi",
        "version" => "1",
        "chainId" => chain_id,
        "salt" => "0x" <> Base.encode16(:crypto.hash(:sha256, "salt:" <> intent_id), case: :lower)
      },
      "primaryType" => "XochiIntent",
      "types" => %{"XochiIntent" => [%{"name" => "intentId", "type" => "string"}]},
      "message" => %{"intentId" => intent_id}
    }
  end

  # A canonical ERC-3009 ReceiveWithAuthorization pull bound to the request: `from`
  # is the buyer, `to` is the pinned solver, `value` == the origin amount, the
  # verifyingContract is the origin token, and validBefore is a bounded future.
  # This is exactly what `Protocols.Xochi.validate_pull/3` checks before signing.
  defp erc3009_pull(intent_id, req) do
    valid_before = Integer.to_string(System.system_time(:second) + 600)

    %{
      "domain" => %{
        "name" => "USD Coin",
        "version" => "2",
        "chainId" => req.from_chain,
        "verifyingContract" => req.from_token
      },
      "primaryType" => "ReceiveWithAuthorization",
      "types" => %{
        "ReceiveWithAuthorization" => [
          %{"name" => "from", "type" => "address"},
          %{"name" => "to", "type" => "address"},
          %{"name" => "value", "type" => "uint256"},
          %{"name" => "validAfter", "type" => "uint256"},
          %{"name" => "validBefore", "type" => "uint256"},
          %{"name" => "nonce", "type" => "bytes32"}
        ]
      },
      "message" => %{
        "from" => req.wallet,
        "to" => req.solver,
        "value" => Integer.to_string(req.amount),
        "validAfter" => "0",
        "validBefore" => valid_before,
        "nonce" => "0x" <> Base.encode16(:crypto.hash(:sha256, intent_id), case: :lower)
      }
    }
  end

  defp execute_body(intent_id, status, extra) do
    Map.merge(
      %{"success" => status == "completed", "intent_id" => intent_id, "status" => status},
      extra
    )
  end

  defp cannot_solve_body(reason) do
    %{
      "intent_id" => "xi_" <> uid(),
      "quote_id" => "xq_" <> uid(),
      "can_solve" => false,
      "error" => reason,
      "settlement_options" => []
    }
  end

  defp unavailable_body do
    %{
      "can_solve" => false,
      "error" => "Solver temporarily unavailable",
      "success" => false,
      "settlement_options" => []
    }
  end

  # -- Helpers --

  defp ok_resp(status, body), do: %{status: status, body: body}

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  # A deterministic 32-byte tx hash per intent, so the deliverable carries a
  # well-formed `0x`-prefixed 64-hex settlement hash.
  defp tx_hash(intent_id),
    do: "0x" <> Base.encode16(:crypto.hash(:sha256, "tx:" <> intent_id), case: :lower)

  defp normalize_inventory(inventory) do
    Map.new(inventory, fn {{chain, token}, amount} -> {{chain, downcase(token)}, amount} end)
  end

  defp downcase(token) when is_binary(token), do: String.downcase(token)

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil

  defp uid, do: Integer.to_string(System.unique_integer([:positive]))
end
