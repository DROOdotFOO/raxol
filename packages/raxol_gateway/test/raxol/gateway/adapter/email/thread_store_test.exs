defmodule Raxol.Gateway.Adapter.Email.ThreadStoreTest do
  use ExUnit.Case, async: true

  alias Raxol.Gateway.Adapter.Email.ThreadStore
  alias Raxol.Gateway.Route

  defp start_store(opts \\ []) do
    start_supervised!({ThreadStore, [name: nil] ++ opts})
  end

  @meta %{message_id: "<m1@x.com>", references: ["<r0@x.com>"], subject: "status"}

  test "record and lookup round-trip" do
    store = start_store()
    assert :ok = ThreadStore.record(store, "bob@x.com", @meta)
    assert {:ok, @meta} = ThreadStore.lookup(store, "bob@x.com")
  end

  test "lookup of an unknown conversation is :none" do
    store = start_store()
    assert :none = ThreadStore.lookup(store, "nobody@x.com")
  end

  test "record_event records email metadata keyed by the route address" do
    store = start_store()
    route = %Route{platform: :email, chat_type: :dm, chat_id: "bob@x.com"}

    assert :ok = ThreadStore.record_event(store, route, %{text: "hi", email: @meta})
    assert {:ok, @meta} = ThreadStore.lookup(store, "bob@x.com")
  end

  test "record_event on an event without :email metadata is a no-op" do
    store = start_store()
    route = %Route{platform: :email, chat_type: :dm, chat_id: "bob@x.com"}

    assert :ok = ThreadStore.record_event(store, route, %{text: "hi"})
    assert :none = ThreadStore.lookup(store, "bob@x.com")
  end

  test "thread_lookup_fn resolves a route to its meta, or nil" do
    store = start_store()
    ThreadStore.record(store, "bob@x.com", @meta)
    lookup = ThreadStore.thread_lookup_fn(store)

    assert lookup.(%Route{platform: :email, chat_type: :dm, chat_id: "bob@x.com"}) == @meta
    assert lookup.(%Route{platform: :email, chat_type: :dm, chat_id: "who@x.com"}) == nil
  end

  test "latest record for a conversation wins" do
    store = start_store()
    ThreadStore.record(store, "bob@x.com", %{message_id: "<old@x>"})
    ThreadStore.record(store, "bob@x.com", %{message_id: "<new@x>"})

    assert {:ok, %{message_id: "<new@x>"}} = ThreadStore.lookup(store, "bob@x.com")
  end

  test "evicts the oldest conversation past :max_entries" do
    store = start_store(max_entries: 2)
    ThreadStore.record(store, "a@x", %{message_id: "<a@x>"})
    ThreadStore.record(store, "b@x", %{message_id: "<b@x>"})
    ThreadStore.record(store, "c@x", %{message_id: "<c@x>"})

    assert :none = ThreadStore.lookup(store, "a@x")
    assert {:ok, _b} = ThreadStore.lookup(store, "b@x")
    assert {:ok, _c} = ThreadStore.lookup(store, "c@x")
  end

  test "re-recording a key refreshes its recency, sparing it from eviction" do
    store = start_store(max_entries: 2)
    ThreadStore.record(store, "a@x", %{message_id: "<a@x>"})
    ThreadStore.record(store, "b@x", %{message_id: "<b@x>"})
    # touch a@x so it is now most-recent; b@x becomes the eviction candidate
    ThreadStore.record(store, "a@x", %{message_id: "<a2@x>"})
    ThreadStore.record(store, "c@x", %{message_id: "<c@x>"})

    assert {:ok, %{message_id: "<a2@x>"}} = ThreadStore.lookup(store, "a@x")
    assert :none = ThreadStore.lookup(store, "b@x")
    assert {:ok, _c} = ThreadStore.lookup(store, "c@x")
  end
end
