defmodule Raxol.Payments.Xochi.ReadTokenStoreTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Checkpoint
  alias Raxol.Payments.Xochi.{ReadTokenStore, SettlementState}

  @prod "https://api.xochi.fi"
  @other "https://staging.xochi.test"
  @token "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"
  @principal "wallet:0x1111111111111111111111111111111111111111"
  @other_principal "wallet:0x2222222222222222222222222222222222222222"
  @now 1_900_000_000

  test "the same intent id under another origin neither fetches nor deletes the token" do
    store = Checkpoint.ETS.new()
    :ok = ReadTokenStore.put(store, @prod, @principal, "int_1", @token, @now)

    assert ReadTokenStore.fetch(store, @other, @principal, "int_1", @now) == nil
    assert ReadTokenStore.fetch(store, @prod, @other_principal, "int_1", @now) == nil

    :ok = ReadTokenStore.delete(store, @other, @principal, "int_1")
    assert ReadTokenStore.fetch(store, @prod, @principal, "int_1", @now) == @token

    :ok = ReadTokenStore.delete(store, @prod, @principal, "int_1")
    assert ReadTokenStore.fetch(store, @prod, @principal, "int_1", @now) == nil
  end

  test "the origin ignores case, the path and the scheme's default port" do
    store = Checkpoint.ETS.new()

    :ok =
      ReadTokenStore.put(
        store,
        "HTTPS://API.Xochi.FI:443/api",
        @principal,
        "int_1",
        @token,
        @now
      )

    assert ReadTokenStore.fetch(store, @prod, @principal, "int_1", @now) == @token

    assert ReadTokenStore.fetch(
             store,
             "https://api.xochi.fi:8443",
             @principal,
             "int_1",
             @now
           ) == nil

    assert ReadTokenStore.fetch(store, "http://api.xochi.fi", @principal, "int_1", @now) == nil
  end

  test "token TTL expires exactly at one hour without sleeping" do
    store = Checkpoint.ETS.new()
    :ok = ReadTokenStore.put(store, @prod, @principal, "int_1", @token, @now)

    assert ReadTokenStore.fetch(store, @prod, @principal, "int_1", @now + 3_599) == @token
    assert ReadTokenStore.fetch(store, @prod, @principal, "int_1", @now + 3_600) == nil
  end

  test "terminal TTL expires exactly at 24 hours without sleeping" do
    store = Checkpoint.ETS.new()
    result = {:ok, %{intent_id: "int_1", status: "completed"}}

    :ok =
      SettlementState.commit_terminal(
        store,
        @prod,
        @principal,
        "int_1",
        result,
        @now
      )

    assert {:ok, ^result} =
             SettlementState.terminal(store, @prod, @principal, "int_1", @now + 86_399)

    assert :error =
             SettlementState.terminal(store, @prod, @principal, "int_1", @now + 86_400)
  end
end
