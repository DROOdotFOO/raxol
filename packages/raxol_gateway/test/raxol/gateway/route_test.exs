defmodule Raxol.Gateway.RouteTest do
  use ExUnit.Case, async: true

  alias Raxol.Gateway.Route

  test "new/1 builds a route from a map" do
    route = Route.new(%{platform: :telegram, chat_type: :private, chat_id: 123, user_id: "u1"})
    assert route.platform == :telegram
    assert route.chat_type == :private
    assert route.chat_id == 123
    assert route.user_id == "u1"
  end

  test "user_id defaults to nil" do
    route = Route.new(%{platform: :webui, chat_type: :dm, chat_id: "abc"})
    assert route.user_id == nil
  end

  test "key/1 builds the unified session key" do
    route = Route.new(%{platform: :telegram, chat_type: :private, chat_id: 123_456_789})
    assert Route.key(route) == "agent:main:telegram:private:123456789"
  end

  test "two chats on the same platform get distinct keys" do
    a = Route.new(%{platform: :telegram, chat_type: :private, chat_id: 1})
    b = Route.new(%{platform: :telegram, chat_type: :private, chat_id: 2})
    refute Route.key(a) == Route.key(b)
  end
end
