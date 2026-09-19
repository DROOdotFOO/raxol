defmodule Raxol.Agent.McpHosts do
  @moduledoc """
  The operator's allowlist of hosts a WORKSPACE-declared MCP server may be
  connected to (ADR-0037 decision 4, the transport half of it).

  `<dir>/.mcp.json` is repository content: a file a clone can carry. A remote
  entry in it names a host, and connecting to that host is not a neutral act.
  The first thing the client does is `tools/list`, and every tool's
  description and input schema is rendered straight into the model's context
  window. A repository that points the agent at a host it controls therefore
  gets to write text into the model's instructions on session start, before
  any tool is called. `sensitive: true` does not help: that gates INVOCATION,
  which is a round too late.

  There is no safe default set of hosts, so the default is none. A
  workspace-sourced remote spec connects only if the operator listed its host
  in `~/.raxol/mcp_hosts.json` (override `$RAXOL_MCP_HOST_ALLOWLIST`) -- an
  operator-owned file outside every workspace, read under the ownership rules
  in `Raxol.Agent.OperatorFile`, exactly like `mcp_headers.json`. A `:user`
  spec is the operator's own declaration and needs no second approval.

      ["mcp.example.com", "intel.internal"]

  Hosts are compared case-insensitively, host only: a scheme, a port or a
  path in the file is not a host and matches nothing. A missing, unreadable,
  untrusted or malformed file is an empty allowlist, because the file exists
  to withhold permission and failing open would grant it.
  """

  require Logger

  alias Raxol.Agent.OperatorFile

  @env "RAXOL_MCP_HOST_ALLOWLIST"
  @filename "mcp_hosts.json"
  @label "mcp host allowlist"

  @type reason :: {:workspace_remote_host, String.t()} | :remote_url_without_host

  @doc """
  Whether this remote server may be connected to.

  Options: `:source` (`:workspace` by default -- an unknown provenance is the
  untrusted one) and `:server`, used only in the refusal log.

  `:ok`, or `{:error, {:workspace_remote_host, host}}` for a host the
  operator has not allowlisted. The refusal names the host in the log so an
  operator can add it deliberately.
  """
  @spec permit(term(), keyword()) :: :ok | {:error, reason()}
  def permit(url, opts \\ []) do
    case Keyword.get(opts, :source, :workspace) do
      :user -> :ok
      _workspace -> permit_workspace(url, Keyword.get(opts, :server))
    end
  end

  defp permit_workspace(url, server) do
    case host(url) do
      nil ->
        {:error, :remote_url_without_host}

      host ->
        if MapSet.member?(allowlist(), host), do: :ok, else: refuse(host, server)
    end
  end

  defp refuse(host, server) do
    Logger.warning(fn ->
      "#{@label}: server #{inspect(server)} is declared by the workspace .mcp.json and points " <>
        "at #{host}, which no operator allowlist names. Not connecting: its tool list would " <>
        "enter the model's context. Add #{host} to #{allowlist_path() || "$#{@env}"} to allow it."
    end)

    {:error, {:workspace_remote_host, host}}
  end

  @doc "The host allowlist path (`$#{@env}` or `~/.raxol/#{@filename}`); nil with no home."
  @spec allowlist_path() :: String.t() | nil
  def allowlist_path, do: OperatorFile.path(@env, @filename)

  @doc "The allowlisted hosts, downcased. Empty unless an operator-owned file says otherwise."
  @spec allowlist() :: MapSet.t(String.t())
  def allowlist do
    case OperatorFile.read(@env, @filename, @label) do
      {:ok, raw} -> decode(raw)
      _absent_or_refused -> MapSet.new()
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, hosts} when is_list(hosts) ->
        hosts
        |> Enum.filter(&is_binary/1)
        |> MapSet.new(&String.downcase/1)

      _malformed ->
        MapSet.new()
    end
  end

  defp host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _no_host -> nil
    end
  end

  defp host(_other), do: nil
end
