defmodule Raxol.Gateway.Adapter.InMemory do
  @moduledoc """
  A reference `Raxol.Gateway.Adapter` with no external platform.

  `connect/1` takes a config map carrying a `:sink` pid; `send_message/3`
  forwards each rendered outbound to that pid as `{:gateway_sent, route,
  rendered}`. `normalize_event/1` reads a raw map of route fields plus an
  `:event`. Useful for driving the full inbound -> session -> outbound path in
  tests without a real platform.
  """

  @behaviour Raxol.Gateway.Adapter

  alias Raxol.Gateway.Route

  @impl true
  def connect(config), do: {:ok, Map.new(config)}

  @impl true
  def disconnect(_conn), do: :ok

  @impl true
  def platform, do: :in_memory

  @impl true
  def normalize_event(%{platform: _, chat_type: _, chat_id: _} = raw) do
    route = Route.new(Map.take(raw, [:platform, :chat_type, :chat_id, :user_id]))
    {:ok, route, Map.get(raw, :event)}
  end

  def normalize_event(_raw), do: :ignore

  @impl true
  def send_message(%{sink: sink}, route, rendered) when is_pid(sink) do
    send(sink, {:gateway_sent, route, rendered})
    :ok
  end

  def send_message(_conn, _route, _rendered), do: :ok
end
