defmodule Raxol.Broker.Executor.Port.MCP do
  @moduledoc """
  A `Raxol.Broker.Executor.Port` over one unregistered `Raxol.MCP.Client`.

  `start/1` takes a `Raxol.MCP.Client` spec (`:url`, `:headers`, and any
  extra keys such as `:resolver` or `:exchange`); `:name` defaults to
  `:broker_executor` and `:registry` is dropped, so the session is never
  reachable by name. The client is linked to the caller, the executor.

  The session is live when its URL's host is `agent.robinhood.com`. Token
  refresh for the live session belongs with arming (#1179), which is also
  what lets the executor use a live port at all.
  """

  @behaviour Raxol.Broker.Executor.Port

  alias Raxol.MCP.Client, as: Upstream

  @live_hosts ["agent.robinhood.com"]
  @ready_timeout 30_000

  defstruct [:pid, :live?]

  @doc "Start the session and wait until it is ready. Returns a port."
  @spec start(keyword()) :: {:ok, Raxol.Broker.Executor.Port.t()} | {:error, term()}
  def start(spec) when is_list(spec) do
    url = Keyword.get(spec, :url)
    spec = spec |> Keyword.delete(:registry) |> Keyword.put_new(:name, :broker_executor)

    with {:ok, pid} <- Upstream.start_link(spec),
         {:ok, _info} <- ready(pid) do
      {:ok, {__MODULE__, %__MODULE__{pid: pid, live?: live_url?(url)}}}
    end
  end

  defp ready(pid) do
    case Upstream.list_tools(pid) do
      {:ok, _tools} -> {:ok, :ready}
      {:error, {:not_ready, _status}} -> Upstream.await_ready(pid, @ready_timeout)
      {:error, reason} -> {:error, reason}
    end
  end

  defp live_url?(url) when is_binary(url), do: URI.parse(url).host in @live_hosts
  defp live_url?(_url), do: false

  @impl true
  def call(%__MODULE__{pid: pid}, tool, args, timeout),
    do: Upstream.call_tool(pid, tool, args, timeout: timeout)

  @impl true
  def live?(%__MODULE__{live?: live?}), do: live?

  @impl true
  def stop(%__MODULE__{pid: pid}) do
    _ = Upstream.stop(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
