defmodule Raxol.Earn.Transport.Mock do
  @moduledoc """
  In-process transport for tests.

  Holds an ETS-backed state per transport instance: connection status,
  the owner pid to deliver entries to, sent-message history, and
  pre-canned entry batches.

  ## Usage in tests

      transport = Raxol.Earn.Transport.Mock.new()
      :ok = Raxol.Earn.Transport.connect(transport, %{owner: self(), ...})
      Raxol.Earn.Transport.Mock.deliver(transport, entry_map)
      # owner receives `{:transport, entry_map}` immediately.

  ## Inspecting outgoing traffic

  `Raxol.Earn.Transport.Mock.sent(transport)` returns every message ever
  sent via `post_message` or `send_message`, in order, as
  `{kind, job_key, content, content_type}` tuples.
  """

  @behaviour Raxol.Earn.Transport

  @doc """
  Construct a fresh mock transport. Each call creates an isolated
  state table.
  """
  @spec new() :: Raxol.Earn.Transport.t()
  def new do
    table = :ets.new(:raxol_earn_transport_mock, [:set, :public])

    :ets.insert(table, {:owner, nil})
    :ets.insert(table, {:connected?, false})
    :ets.insert(table, {:sent, []})
    :ets.insert(table, {:history, %{}})

    %{adapter: __MODULE__, config: %{table: table}}
  end

  @doc "Manually push an entry to the connected owner."
  @spec deliver(Raxol.Earn.Transport.t(), Raxol.Earn.Transport.entry()) :: :ok
  def deliver(%{config: %{table: table}}, entry) do
    case :ets.lookup(table, :owner) do
      [{:owner, nil}] ->
        :ok

      [{:owner, owner}] when is_pid(owner) ->
        send(owner, {:transport, entry})
        :ok
    end
  end

  @doc "Set the history fixture returned by `get_history/2`."
  @spec set_history(Raxol.Earn.Transport.t(), Raxol.Earn.Transport.job_key(), [
          Raxol.Earn.Transport.entry()
        ]) :: :ok
  def set_history(%{config: %{table: table}}, key, entries) do
    [{:history, current}] = :ets.lookup(table, :history)
    :ets.insert(table, {:history, Map.put(current, key, entries)})
    :ok
  end

  @doc "Return every outbound message that's been sent through this transport."
  @spec sent(Raxol.Earn.Transport.t()) :: [tuple()]
  def sent(%{config: %{table: table}}) do
    [{:sent, list}] = :ets.lookup(table, :sent)
    Enum.reverse(list)
  end

  @doc "Whether `connect/2` has been called and not yet `disconnect/1`'d."
  @spec connected?(Raxol.Earn.Transport.t()) :: boolean()
  def connected?(%{config: %{table: table}}) do
    [{:connected?, c}] = :ets.lookup(table, :connected?)
    c
  end

  # -- Raxol.Earn.Transport callbacks --

  @impl Raxol.Earn.Transport
  def connect(%{config: %{table: table}}, %{owner: owner}) do
    :ets.insert(table, {:owner, owner})
    :ets.insert(table, {:connected?, true})
    :ok
  end

  @impl Raxol.Earn.Transport
  def disconnect(%{config: %{table: table}}) do
    :ets.insert(table, {:owner, nil})
    :ets.insert(table, {:connected?, false})
    :ok
  end

  @impl Raxol.Earn.Transport
  def get_history(%{config: %{table: table}}, key) do
    [{:history, h}] = :ets.lookup(table, :history)
    {:ok, Map.get(h, key, [])}
  end

  @impl Raxol.Earn.Transport
  def post_message(%{config: %{table: table}}, key, content, content_type) do
    record_sent(table, {:post, key, content, content_type})
    :ok
  end

  @impl Raxol.Earn.Transport
  def send_message(%{config: %{table: table}}, key, content, content_type) do
    record_sent(table, {:send, key, content, content_type})
    :ok
  end

  defp record_sent(table, entry) do
    [{:sent, list}] = :ets.lookup(table, :sent)
    :ets.insert(table, {:sent, [entry | list]})
  end
end
