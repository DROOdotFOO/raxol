defmodule Raxol.Payments.Mandate.StoreTest do
  use ExUnit.Case, async: false

  alias Raxol.Payments.Mandate
  alias Raxol.Payments.Mandate.Store

  @test_privkey "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

  defmodule TestWallet do
    @moduledoc false
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_STORE_TEST_KEY"
  end

  setup do
    System.put_env("RAXOL_STORE_TEST_KEY", @test_privkey)

    safe_stop_store()
    {:ok, _pid} = Store.start_link([])
    Store.clear()
    :ok
  end

  defp safe_stop_store do
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
  end

  defp signed_mandate(overrides \\ %{}) do
    addr = TestWallet.address()
    agent = Map.get(overrides, :agent_wallet, "0x" <> String.duplicate("aa", 20))

    base = %{
      human_wallet: addr,
      agent_wallet: agent,
      scopes: Map.get(overrides, :scopes, ["quote", "execute"]),
      max_amount_usd: 1000,
      max_calls: 50,
      expires_at: Map.get(overrides, :expires_at, System.system_time(:second) + 3600)
    }

    {:ok, m} = Mandate.build(base)
    {:ok, signed} = Mandate.sign(m, TestWallet)
    signed
  end

  describe "put/2" do
    test "rejects unsigned mandates" do
      {:ok, m} =
        Mandate.build(%{
          human_wallet: TestWallet.address(),
          agent_wallet: "0x" <> String.duplicate("aa", 20),
          scopes: ["quote"],
          max_amount_usd: 100,
          max_calls: 1,
          expires_at: System.system_time(:second) + 60
        })

      assert {:error, :unsigned} = Store.put(m)
    end

    test "persists signed mandates" do
      m = signed_mandate()
      assert :ok = Store.put(m)
      assert {:ok, ^m} = Store.get(m.envelope_hash)
    end

    test "overwrite of same envelope_hash does not duplicate index entries" do
      m = signed_mandate()
      :ok = Store.put(m)
      :ok = Store.put(m)
      assert length(Store.list_for_agent(m.agent_wallet)) == 1
      assert length(Store.list_for_member(m.human_wallet)) == 1
    end
  end

  describe "get/1" do
    test "returns :error for unknown hash" do
      assert :error = Store.get(:crypto.strong_rand_bytes(32))
    end
  end

  describe "list_for_agent/1 and list_for_member/1" do
    test "indexes by both wallets" do
      m1 = signed_mandate(%{agent_wallet: "0x" <> String.duplicate("aa", 20)})
      m2 = signed_mandate(%{agent_wallet: "0x" <> String.duplicate("bb", 20)})
      :ok = Store.put(m1)
      :ok = Store.put(m2)

      aa = String.downcase("0x" <> String.duplicate("aa", 20))
      bb = String.downcase("0x" <> String.duplicate("bb", 20))

      assert [^m1] = Store.list_for_agent(aa)
      assert [^m2] = Store.list_for_agent(bb)

      member_listings = Store.list_for_member(m1.human_wallet)
      assert length(member_listings) == 2
      assert m1 in member_listings
      assert m2 in member_listings
    end

    test "returns [] for unknown wallet" do
      assert Store.list_for_agent("0x" <> String.duplicate("ff", 20)) == []
      assert Store.list_for_member("0x" <> String.duplicate("ff", 20)) == []
    end
  end

  describe "delete/1" do
    test "removes the mandate and its secondary indices" do
      m = signed_mandate()
      :ok = Store.put(m)
      :ok = Store.delete(m.envelope_hash)
      assert :error = Store.get(m.envelope_hash)
      assert Store.list_for_agent(m.agent_wallet) == []
      assert Store.list_for_member(m.human_wallet) == []
    end

    test "is idempotent" do
      :ok = Store.delete(:crypto.strong_rand_bytes(32))
      :ok = Store.delete(:crypto.strong_rand_bytes(32))
    end
  end

  describe "sweep_expired/0" do
    test "removes expired mandates and reports the count" do
      live = signed_mandate(%{expires_at: System.system_time(:second) + 3600})
      dead1 = signed_mandate(%{expires_at: 1, agent_wallet: "0x" <> String.duplicate("11", 20)})
      dead2 = signed_mandate(%{expires_at: 2, agent_wallet: "0x" <> String.duplicate("22", 20)})

      :ok = Store.put(live)
      :ok = Store.put(dead1)
      :ok = Store.put(dead2)

      assert Store.sweep_expired() == 2
      assert {:ok, ^live} = Store.get(live.envelope_hash)
      assert :error = Store.get(dead1.envelope_hash)
      assert :error = Store.get(dead2.envelope_hash)
    end
  end

  describe "DETS persistence" do
    @tag :tmp_dir
    test "round-trips through DETS file", %{tmp_dir: tmp} do
      path = Path.join(tmp, "mandates.dets")
      m = signed_mandate()

      # Stop the in-memory store from setup so we can restart with DETS.
      GenServer.stop(Store, :normal, 1_000)

      Application.put_env(:raxol_payments, :mandate_store_path, path)

      try do
        {:ok, _} = Store.start_link([])
        :ok = Store.put(m)
        assert {:ok, ^m} = Store.get(m.envelope_hash)

        safe_stop_store()

        {:ok, _} = Store.start_link([])
        assert {:ok, restored} = Store.get(m.envelope_hash)
        assert restored.envelope_hash == m.envelope_hash
        assert restored.signature == m.signature
        assert restored.scopes == m.scopes

        assert [_one] = Store.list_for_agent(m.agent_wallet)
        assert [_one] = Store.list_for_member(m.human_wallet)
      after
        Application.delete_env(:raxol_payments, :mandate_store_path)
        safe_stop_store()
      end
    end
  end
end
