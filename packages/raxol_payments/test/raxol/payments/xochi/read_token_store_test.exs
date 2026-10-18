defmodule Raxol.Payments.Xochi.ReadTokenStoreTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Checkpoint
  alias Raxol.Payments.Xochi.ReadTokenStore

  @prod "https://api.xochi.fi"
  @other "https://staging.xochi.test"
  @token "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"

  test "the same intent id under another origin neither fetches nor deletes the token" do
    store = Checkpoint.ETS.new()
    :ok = ReadTokenStore.put(store, @prod, "int_1", @token)

    assert ReadTokenStore.fetch(store, @other, "int_1") == nil

    :ok = ReadTokenStore.delete(store, @other, "int_1")
    assert ReadTokenStore.fetch(store, @prod, "int_1") == @token

    :ok = ReadTokenStore.delete(store, @prod, "int_1")
    assert ReadTokenStore.fetch(store, @prod, "int_1") == nil
  end

  test "the origin ignores case, the path and the scheme's default port" do
    store = Checkpoint.ETS.new()
    :ok = ReadTokenStore.put(store, "HTTPS://API.Xochi.FI:443/api", "int_1", @token)

    assert ReadTokenStore.fetch(store, @prod, "int_1") == @token
    assert ReadTokenStore.fetch(store, "https://api.xochi.fi:8443", "int_1") == nil
    assert ReadTokenStore.fetch(store, "http://api.xochi.fi", "int_1") == nil
  end
end
