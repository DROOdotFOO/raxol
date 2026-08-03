defmodule Raxol.Earn.AuthTest do
  @moduledoc """
  Live tests for `Raxol.Earn.Auth` against the real Virtuals dev API at
  `https://api-dev.acp.virtuals.io`. No mocks -- the EIP-712 typed data
  is signed and POSTed for real; the JWT comes back from the real
  server.

  Tagged `:live_acp_dev`. Skipped by default unless
  `RAXOL_ACP_AGENT_PRIVATE_KEY` is set.

      RAXOL_ACP_AGENT_PRIVATE_KEY=0x<32-byte hex> \\
        mix test test/raxol/acp/auth_test.exs --include live_acp_dev
  """
  use ExUnit.Case, async: false

  alias Raxol.Earn.Auth
  alias Raxol.Earn.ProviderAdapter.JSONRPC

  @moduletag :live_acp_dev

  setup_all do
    case load_credentials() do
      {:ok, creds} ->
        {:ok, creds}

      :error ->
        {:skip,
         "RAXOL_ACP_AGENT_PRIVATE_KEY not set -- skipping live Virtuals dev API tests. " <>
           "Set the env var to a 32-byte hex private key for a registered dev-API agent."}
    end
  end

  setup ctx do
    {:ok, auth} =
      Auth.start_link(
        provider: ctx.provider,
        server_url: ctx.server_url,
        chain_id: 8453
      )

    %{auth: auth}
  end

  describe "token/1 against real Virtuals dev API" do
    test "first call performs EIP-712 sign + POST /auth/agent + JWT decode", %{auth: auth} do
      assert {:ok, token} = Auth.token(auth)
      assert is_binary(token)

      assert [_h, _payload, _sig] = String.split(token, ".")

      state = Auth.get_state(auth)
      assert state.token == token
      assert is_integer(state.expires_at_ms)
      assert state.expires_at_ms > System.system_time(:millisecond)
    end

    test "subsequent calls return the cached token", %{auth: auth} do
      assert {:ok, t1} = Auth.token(auth)
      assert {:ok, t2} = Auth.token(auth)
      assert t1 == t2
    end

    test "invalidate/1 forces a fresh authentication", %{auth: auth} do
      assert {:ok, t1} = Auth.token(auth)
      :ok = Auth.invalidate(auth)
      state = Auth.get_state(auth)
      assert state.token == nil

      assert {:ok, t2} = Auth.token(auth)
      assert is_binary(t2)
      # The dev API may or may not issue the same JWT depending on its
      # implementation; we don't assert difference, just that we got one.
    end
  end

  # -- Credential loading --

  defp load_credentials do
    with {:ok, pk_hex} <- System.fetch_env("RAXOL_ACP_AGENT_PRIVATE_KEY"),
         {:ok, pk} <- decode_private_key(pk_hex) do
      server_url =
        System.get_env("RAXOL_ACP_SERVER_URL", "https://api-dev.acp.virtuals.io")

      rpc_url = System.get_env("RAXOL_ACP_RPC_URL", "https://mainnet.base.org")

      provider =
        JSONRPC.new(
          chains: %{8453 => rpc_url},
          private_key: pk
        )

      {:ok, provider: provider, server_url: server_url}
    else
      _ -> :error
    end
  end

  defp decode_private_key("0x" <> hex) when byte_size(hex) == 64,
    do: {:ok, Base.decode16!(hex, case: :mixed)}

  defp decode_private_key(hex) when byte_size(hex) == 64,
    do: {:ok, Base.decode16!(hex, case: :mixed)}

  defp decode_private_key(_), do: :error
end
