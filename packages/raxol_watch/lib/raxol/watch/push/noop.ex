defmodule Raxol.Watch.Push.Noop do
  @moduledoc """
  Silent push backend for testing.

  Records all push calls so tests can assert on what was sent.
  """

  @behaviour Raxol.Watch.Push.Backend

  use Agent

  require Logger

  @mix_env if Code.ensure_loaded?(Mix), do: Mix.env(), else: :prod
  @warn_on_start @mix_env not in [:test, :dev]

  def start_link(_opts \\ []) do
    if @warn_on_start do
      Logger.warning(
        "Raxol.Watch.Push.Noop is running outside test/dev -- push notifications will be silently discarded. Configure a real backend (APNS/FCM) for production."
      )
    end

    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @impl true
  def push(device_token, notification) do
    Agent.update(__MODULE__, &[{device_token, notification} | &1])
    :ok
  end

  @doc "Returns all pushes sent, newest first."
  @spec get_pushes() :: [{String.t(), map()}]
  def get_pushes do
    Agent.get(__MODULE__, & &1)
  end

  @doc "Clears the push history."
  @spec clear() :: :ok
  def clear do
    Agent.update(__MODULE__, fn _ -> [] end)
  end
end
