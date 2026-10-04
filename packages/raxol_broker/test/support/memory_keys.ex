defmodule Raxol.Broker.Test.MemoryKeys do
  @moduledoc """
  A `Raxol.Broker.KeyProvider` that keeps the key in an `Agent`, so store
  tests exercise the real envelope and file handling without touching the
  user's keychain or 1Password. Start one per test with `start/0` and pass
  `key_provider: {Raxol.Broker.Test.MemoryKeys, agent: agent}`.
  """

  @behaviour Raxol.Broker.KeyProvider

  @spec start() :: pid()
  def start do
    {:ok, agent} = Agent.start_link(fn -> nil end)
    agent
  end

  @impl true
  def load_key(opts) do
    case Agent.get(Keyword.fetch!(opts, :agent), & &1) do
      nil -> :none
      key -> {:ok, key}
    end
  end

  @impl true
  def create_key(opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :agent), fn
      nil ->
        key = :crypto.strong_rand_bytes(32)
        {{:ok, key}, key}

      key ->
        {{:ok, key}, key}
    end)
  end
end
