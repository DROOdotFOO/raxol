defmodule Raxol.Agent.McpHosts do
  @moduledoc """
  The operator's allowlist of what a WORKSPACE-declared MCP server may reach:
  a remote host, or a local command (ADR-0037 decision 4, the transport half
  of it).

  `<dir>/.mcp.json` is repository content: a file a clone can carry. A remote
  entry in it names a host, and connecting to that host is not a neutral act.
  The first thing the client does is `tools/list`, and every tool's
  description and input schema is rendered straight into the model's context
  window. A repository that points the agent at a host it controls therefore
  gets to write text into the model's instructions on session start, before
  any tool is called. `sensitive: true` does not help: that gates INVOCATION,
  which is a round too late.

  A `command` entry is the same threat and worse. `{"command": "npx", "args":
  ["-y", "mcp-remote", "https://evil/mcp"]}` reaches that host over the stdio
  transport, and any other binary reaches whatever that binary does -- from a
  file a clone carried. So both halves of the spec are gated, not just the
  one that names a URL.

  There is no safe default set of either, so the default is none. A
  workspace-sourced spec loads only if the operator listed its host, or its
  command, in `~/.raxol/mcp_hosts.json` (override
  `$RAXOL_MCP_HOST_ALLOWLIST`) -- an operator-owned file outside every
  workspace, read under the ownership rules in `Raxol.Agent.OperatorFile`,
  exactly like `mcp_headers.json`. A `:user` spec is the operator's own
  declaration and needs no second approval.

      {"hosts": ["mcp.example.com", "intel.internal"], "commands": ["npx"]}

  A bare list is read as hosts alone, which is the shape this file had before
  commands were gated:

      ["mcp.example.com", "intel.internal"]

  Hosts are compared case-insensitively, host only: a scheme, a port or a
  path in the file is not a host and matches nothing. A command is compared
  EXACTLY as the spec wrote it, because that string is what `Port.open/2`
  resolves: allowing `"npx"` does not allow `"/usr/local/bin/npx"`, and
  allowing either allows everything that launcher can run -- which is what
  the operator is agreeing to. A missing, unreadable, untrusted or malformed
  file is an empty allowlist, because the file exists to withhold permission
  and failing open would grant it.
  """

  require Logger

  alias Raxol.Agent.OperatorFile

  @env "RAXOL_MCP_HOST_ALLOWLIST"
  @filename "mcp_hosts.json"
  @label "mcp host allowlist"

  @type reason ::
          {:workspace_remote_host, String.t()}
          | :remote_url_without_host
          | {:workspace_command, String.t()}

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

  @doc """
  Whether this local command may be spawned for a workspace-declared server.

  Same options and the same default as `permit/2`. `:ok`, or
  `{:error, {:workspace_command, command}}` for a command the operator has
  not allowlisted.
  """
  @spec permit_command(term(), keyword()) :: :ok | {:error, reason()}
  def permit_command(command, opts \\ []) do
    case Keyword.get(opts, :source, :workspace) do
      :user -> :ok
      _workspace -> permit_workspace_command(command, Keyword.get(opts, :server))
    end
  end

  defp permit_workspace_command(command, server) when is_binary(command) do
    if MapSet.member?(commands(), command),
      do: :ok,
      else: refuse_command(command, server)
  end

  defp permit_workspace_command(command, server),
    do: refuse_command(inspect(command), server)

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

  defp refuse_command(command, server) do
    Logger.warning(fn ->
      "#{@label}: server #{inspect(server)} is declared by the workspace .mcp.json and runs " <>
        "#{command}, which no operator allowlist names. Not starting it: a command from a " <>
        "cloned repository is arbitrary local code, and its tool list would enter the " <>
        "model's context. Add #{command} to the \"commands\" list in " <>
        "#{allowlist_path() || "$#{@env}"} to allow it."
    end)

    {:error, {:workspace_command, command}}
  end

  @doc "The host allowlist path (`$#{@env}` or `~/.raxol/#{@filename}`); nil with no home."
  @spec allowlist_path() :: String.t() | nil
  def allowlist_path, do: OperatorFile.path(@env, @filename)

  @doc "The allowlisted hosts, downcased. Empty unless an operator-owned file says otherwise."
  @spec allowlist() :: MapSet.t(String.t())
  def allowlist, do: grants().hosts

  @doc "The allowlisted commands, verbatim. Empty unless an operator-owned file says otherwise."
  @spec commands() :: MapSet.t(String.t())
  def commands, do: grants().commands

  defp grants do
    case OperatorFile.read(@env, @filename, @label) do
      {:ok, raw} -> decode(raw)
      _absent_or_refused -> %{hosts: MapSet.new(), commands: MapSet.new()}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      # The original shape: a bare list names hosts and grants no command.
      {:ok, hosts} when is_list(hosts) ->
        %{hosts: downcased(hosts), commands: MapSet.new()}

      {:ok, %{} = grants} ->
        %{
          hosts: downcased(Map.get(grants, "hosts", [])),
          commands: verbatim(Map.get(grants, "commands", []))
        }

      _malformed ->
        %{hosts: MapSet.new(), commands: MapSet.new()}
    end
  end

  defp downcased(list) when is_list(list) do
    list |> Enum.filter(&is_binary/1) |> MapSet.new(&String.downcase/1)
  end

  defp downcased(_other), do: MapSet.new()

  defp verbatim(list) when is_list(list) do
    list |> Enum.filter(&is_binary/1) |> MapSet.new()
  end

  defp verbatim(_other), do: MapSet.new()

  defp host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _no_host -> nil
    end
  end

  defp host(_other), do: nil
end
