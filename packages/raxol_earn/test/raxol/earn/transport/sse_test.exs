defmodule Raxol.Earn.Transport.SSETest do
  @moduledoc """
  Live tests for `Raxol.Earn.Transport.SSE` against the real Virtuals
  dev API. Verifies the SSE connection opens cleanly and entries
  arrive in the documented shape.

  Skipped unless `RAXOL_ACP_AGENT_PRIVATE_KEY` is set.
  """
  use ExUnit.Case, async: false

  alias Raxol.Earn.{Auth, Transport}
  alias Raxol.Earn.Transport.SSE
  alias Raxol.Earn.ProviderAdapter.JSONRPC

  @moduletag :live_acp_dev

  # ExUnit has no runtime skip: a callback returning {:skip, _} raises and
  # invalidates the module. Decide at load time -- .exs files are re-evaluated
  # every run, so this still tracks the credential. A skipped module never runs
  # setup_all, so the key is present by the time it does.
  if System.fetch_env("RAXOL_ACP_AGENT_PRIVATE_KEY") == :error do
    @moduletag skip: "RAXOL_ACP_AGENT_PRIVATE_KEY not set -- live Virtuals dev API tests"
  end

  setup_all do
    pk = decode_pk(System.fetch_env!("RAXOL_ACP_AGENT_PRIVATE_KEY"))

    server_url =
      System.get_env("RAXOL_ACP_SERVER_URL", "https://api-dev.acp.virtuals.io")

    rpc_url = System.get_env("RAXOL_ACP_RPC_URL", "https://mainnet.base.org")

    provider = JSONRPC.new(chains: %{8453 => rpc_url}, private_key: pk)

    {:ok, auth} = Auth.start_link(provider: provider, server_url: server_url, chain_id: 8453)

    {:ok, auth: auth, server_url: server_url, provider: provider}
  end

  setup ctx do
    transport =
      SSE.new(
        auth: ctx.auth,
        server_url: ctx.server_url,
        supported_chain_ids: [8453]
      )

    %{transport: transport}
  end

  describe "connect/2 + disconnect/1" do
    test "opens the stream and disconnect cleanly stops it", %{transport: transport} do
      assert :ok =
               Transport.connect(transport, %{
                 owner: self(),
                 chain_ids: [8453],
                 wallet_address: "0x" <> String.duplicate("0", 40)
               })

      # Give the stream up to 5s to either dump cached entries (if our
      # agent has any active jobs) or just idle. Either is success.
      receive do
        {:transport, entry} ->
          assert is_map(entry)
      after
        5_000 -> :ok
      end

      :ok = Transport.disconnect(transport)
    end
  end

  defp decode_pk("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp decode_pk(hex), do: Base.decode16!(hex, case: :mixed)
end
