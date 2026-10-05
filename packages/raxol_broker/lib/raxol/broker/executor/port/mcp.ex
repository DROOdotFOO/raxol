defmodule Raxol.Broker.Executor.Port.MCP do
  @moduledoc """
  A `Raxol.Broker.Executor.Port` over one unregistered `Raxol.MCP.Client`.

  `start/2` takes a `Raxol.MCP.Client` spec (`:url`, `:headers`, and any
  extra keys such as `:resolver` or `:exchange`); `:name` defaults to
  `:broker_executor` and `:registry` is dropped, so the session is never
  reachable by name. The client is linked to the caller, the executor.

  ## Liveness, decided before connecting

  `live_spec?/1` reads the spec, not a connected session. A spec is live
  unless it says `sandbox: true` AND its `:url` names a host outside
  `robinhood.com` (compared lowercased, trailing dot stripped) AND it has no
  `:command`. A stdio spec is always live: nothing in it says where the
  process sends orders. A spec that is not a keyword list, or that repeats
  `:url`, `:sandbox` or `:command`, is live too: `Raxol.MCP.Client` reads a
  keyword spec through `Map.new/1`, so the last value wins, and a reader
  that took the first one could pass a spec the client then dials somewhere
  else.

  `start/2` checks and connects with one list: `prepare/2` refuses
  duplicates, normalizes the spec the way the client does
  (`spec |> Map.new() |> Map.to_list()`), decides liveness on that
  normalized list and hands that same list (less `:sandbox` and
  `:registry`) to `Raxol.MCP.Client.start_link/1`. In `:dry_run` a live spec
  is refused before any connection; `:armed` is refused until arming exists
  (#1179).
  """

  @behaviour Raxol.Broker.Executor.Port

  alias Raxol.MCP.Client, as: Upstream

  @ready_timeout 30_000
  @single_keys [:url, :sandbox, :command]

  defstruct [:pid]

  @doc """
  Start the session and wait until it is ready. Options: `:mode`
  (`:dry_run` or `:armed`, required) and `:call_timeout`, put into the
  client spec so the client's own timer matches the executor's.
  """
  @spec start(keyword(), keyword()) :: {:ok, Raxol.Broker.Executor.Port.t()} | {:error, term()}
  def start(spec, opts) when is_list(spec) and is_list(opts) do
    with {:ok, client_spec} <- prepare(spec, opts),
         {:ok, pid} <- Upstream.start_link(client_spec),
         {:ok, _info} <- ready(pid) do
      {:ok, {__MODULE__, %__MODULE__{pid: pid}}}
    end
  end

  @doc false
  # The exact list `start/2` passes to `Raxol.MCP.Client.start_link/1`, or
  # the refusal. Public so the tests can see what was checked is what
  # connects.
  @spec prepare(keyword(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def prepare(spec, opts) when is_list(spec) and is_list(opts) do
    with :ok <- admit_mode(Keyword.get(opts, :mode)),
         {:ok, normalized} <- normalize(spec),
         :ok <- admit_spec(normalized) do
      {:ok, client_spec(normalized, opts)}
    end
  end

  defp admit_mode(:dry_run), do: :ok
  defp admit_mode(:armed), do: {:error, :not_armed}
  defp admit_mode(mode), do: {:error, {:invalid_mode, mode}}

  defp normalize(spec) do
    if Keyword.keyword?(spec) and not duplicated?(spec),
      do: {:ok, spec |> Map.new() |> Map.to_list()},
      else: {:error, :live_port_in_dry_run}
  end

  defp admit_spec(normalized),
    do: if(live_spec?(normalized), do: {:error, :live_port_in_dry_run}, else: :ok)

  defp client_spec(spec, opts) do
    spec =
      spec
      |> Keyword.delete(:registry)
      |> Keyword.delete(:sandbox)
      |> Keyword.put_new(:name, :broker_executor)

    case Keyword.get(opts, :call_timeout) do
      nil -> spec
      ms when is_integer(ms) and ms > 0 -> Keyword.put(spec, :call_timeout, ms)
    end
  end

  @doc "Does `spec` reach a real brokerage? See the moduledoc."
  @spec live_spec?(keyword()) :: boolean()
  def live_spec?(spec) when is_list(spec) do
    if Keyword.keyword?(spec) and not duplicated?(spec) do
      case Map.new(spec) do
        %{command: _} -> true
        %{sandbox: true, url: url} when is_binary(url) -> url |> host() |> live_host?()
        _ -> true
      end
    else
      true
    end
  end

  defp duplicated?(spec),
    do: Enum.any?(@single_keys, &(length(Keyword.get_values(spec, &1)) > 1))

  defp host(url) do
    case URI.parse(url).host do
      host when is_binary(host) and host != "" ->
        host |> String.downcase() |> String.trim_trailing(".")

      _ ->
        nil
    end
  end

  defp live_host?(nil), do: true
  defp live_host?("robinhood.com"), do: true
  defp live_host?(host), do: String.ends_with?(host, ".robinhood.com")

  defp ready(pid) do
    case Upstream.list_tools(pid) do
      {:ok, _tools} -> {:ok, :ready}
      {:error, {:not_ready, _status}} -> Upstream.await_ready(pid, @ready_timeout)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def call(%__MODULE__{pid: pid}, tool, args, timeout),
    do: Upstream.call_tool(pid, tool, args, timeout: timeout)

  @impl true
  def stop(%__MODULE__{pid: pid}) do
    _ = Upstream.stop(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
