defmodule Raxol.Payments.Req.MandateTest do
  use ExUnit.Case, async: false

  alias Raxol.Payments.Mandate
  alias Raxol.Payments.Mandate.Store
  alias Raxol.Payments.Req.Mandate, as: ReqMandate

  @test_privkey "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

  defmodule TestWallet do
    @moduledoc false
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_REQ_MANDATE_TEST_KEY"
  end

  @agent "0x" <> String.duplicate("aa", 20)

  setup do
    System.put_env("RAXOL_REQ_MANDATE_TEST_KEY", @test_privkey)

    case GenServer.whereis(Store) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
    end

    {:ok, _} = Store.start_link([])
    Store.clear()
    :ok
  end

  defp put_mandate(opts \\ []) do
    {:ok, m} =
      Mandate.build(%{
        human_wallet: TestWallet.address(),
        agent_wallet: Keyword.get(opts, :agent_wallet, @agent),
        scopes: Keyword.get(opts, :scopes, ["quote", "execute", "stealth_claim"]),
        max_amount_usd: 1000,
        max_calls: 50,
        expires_at: Keyword.get(opts, :expires_at, System.system_time(:second) + 3600)
      })

    {:ok, signed} = Mandate.sign(m, TestWallet)
    :ok = Store.put(signed)
    signed
  end

  defp request_with_step(url) do
    Req.new(url: url)
    |> ReqMandate.attach(agent_wallet: @agent)
  end

  defp header_after_step(req) do
    {ran, _resp} = Req.Request.run_request(req)
    Req.Request.get_header(ran, "x-xochi-delegation")
  end

  describe "attach/2" do
    test "sets X-Xochi-Delegation when a mandate covers the path" do
      mandate = put_mandate()
      {:ok, expected_envelope} = Mandate.to_envelope(mandate)

      header = header_after_step(request_with_step("https://api.xochi.fi/api/intent/quote"))
      assert header == [expected_envelope]
    end

    test "maps /api/intent/execute to scope execute" do
      put_mandate(scopes: ["execute"])

      header = header_after_step(request_with_step("https://api.xochi.fi/api/intent/execute"))
      assert [_] = header
    end

    test "maps /api/settlement/claim to scope stealth_claim" do
      put_mandate(scopes: ["stealth_claim"])

      header = header_after_step(request_with_step("https://api.xochi.fi/api/settlement/claim"))
      assert [_] = header
    end

    test "does not attach on a non-Xochi host" do
      put_mandate()

      header = header_after_step(request_with_step("https://example.com/api/intent/quote"))
      assert header == []
    end

    test "does not attach when path has no scope mapping" do
      put_mandate()

      header = header_after_step(request_with_step("https://api.xochi.fi/api/prices"))
      assert header == []
    end

    test "does not attach when no mandate covers the requested scope" do
      put_mandate(scopes: ["execute"])

      header = header_after_step(request_with_step("https://api.xochi.fi/api/settlement/claim"))
      assert header == []
    end

    test "does not attach when the only matching mandate is expired" do
      put_mandate(expires_at: 1)

      header = header_after_step(request_with_step("https://api.xochi.fi/api/intent/quote"))
      assert header == []
    end

    test "subdomain of allowed host is accepted" do
      put_mandate()

      header = header_after_step(request_with_step("https://staging.xochi.fi/api/intent/quote"))
      assert [_] = header
    end

    test "custom hosts allowlist works" do
      put_mandate()

      req =
        Req.new(url: "https://my-xochi.example.com/api/intent/quote")
        |> ReqMandate.attach(agent_wallet: @agent, hosts: ["my-xochi.example.com"])

      assert [_] = header_after_step(req)
    end

    test "missing agent_wallet option is a no-op" do
      put_mandate()

      req =
        Req.new(url: "https://api.xochi.fi/api/intent/quote")
        |> ReqMandate.attach([])

      assert header_after_step(req) == []
    end

    test "selects soonest-expiring mandate when multiple cover the scope" do
      far = put_mandate(expires_at: System.system_time(:second) + 7200)
      near = put_mandate(expires_at: System.system_time(:second) + 60)

      {:ok, near_envelope} = Mandate.to_envelope(near)
      {:ok, far_envelope} = Mandate.to_envelope(far)

      header = header_after_step(request_with_step("https://api.xochi.fi/api/intent/quote"))
      assert header == [near_envelope]
      refute header == [far_envelope]
    end
  end
end
