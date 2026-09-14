defmodule Raxol.Agent.McpBundle do
  @moduledoc """
  Start external MCP servers from specs and wrap their tools as
  `Raxol.Agent.Action.Dynamic` values for the ReAct loop.

  A Console runtime bundles a default set of standard MCP servers at provision
  so the agent advertises a broad, real toolset (filesystem, fetch, git, ...)
  without hand-writing Actions. Each server's tools are namespaced
  `mcp__<server>__<tool>` and dispatch through the same authorizer + hook chain
  as any Action (see `Raxol.Agent.Action.ToolConverter`); add the returned tools
  to the `:actions` list handed to `Raxol.Agent.Stream.react/2`.

  Loading is FAIL-OPEN per server: a server that fails to start or list its
  tools is logged and skipped, so one broken or uninstalled server never denies
  the agent the rest of its tools.

  Discovered tools are `sensitive: true` unless a spec says otherwise, so the
  default `ToolPolicy.deny_sensitive` authorizer gates a bundled tool until an
  operator opts in. See `default_servers/1` for the per-server posture. A tool
  whose spec declares a per-call price cannot opt out of that: it is stamped
  `sensitive: true` regardless, plus the price and the metered origin that
  `Raxol.Agent.McpSpendHook` reserves against.

  ## Two transports, one spec shape

  A spec carries `:command` (a local stdio subprocess) XOR `:url` (a remote
  HTTP server, ADR-0037). Both keys, or neither, is
  `{:error, {:invalid_spec, _}}` rather than a silent preference for one, and
  the refusal names the server and what was wrong with it -- never the spec
  itself, whose `:env` and `:headers` hold secrets.

  A remote spec's header values are resolved at connect time by
  `Raxol.Agent.McpHeaders`, which is where the provenance rule lives: a
  workspace-sourced spec cannot resolve an `${env:}` or `op://` reference
  unless the operator allowlisted it outside the workspace. A refused
  resolution skips that server like any other load failure.
  """

  require Logger

  alias Raxol.Agent.Action.Dynamic
  alias Raxol.Agent.McpHeaders

  # An MCP client reports `{:not_ready, :initializing}` until its initialize
  # handshake round-trips; without waiting, a freshly started server lists zero
  # tools. Poll readiness up to this budget before giving up (fail-open). The
  # budget is a SINGLE shared deadline across the whole bundle (clients start
  # concurrently first), so N slow servers cannot stall boot for N * timeout.
  @default_ready_timeout_ms 15_000
  @default_ready_interval_ms 100

  @type server_spec :: %{
          required(:name) => atom(),
          optional(:command) => String.t(),
          optional(:args) => [String.t()],
          optional(:env) => [{String.t(), String.t()}],
          optional(:url) => String.t(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:source) => :workspace | :user,
          optional(:metered) => boolean(),
          optional(:prices) => %{optional(String.t()) => pos_integer()},
          optional(:concurrency) => :stateless | :pooled | :serialized,
          optional(:sensitive) => boolean()
        }

  @type loaded :: %{
          tools: [Dynamic.t()],
          servers: [{atom(), pid()}],
          failed: [{atom(), term()}]
        }

  @doc """
  Start each server spec and collect its tools as `Dynamic` values.

  Options:

    * `:start` -- `(keyword() -> {:ok, pid()} | {:error, term()})`, how a client
      is started (default `&Raxol.MCP.Client.start_link/1`). Injectable for
      tests and for a supervised start.
    * `:ready_timeout` -- ms for the WHOLE bundle's initialize handshakes, a
      single shared deadline (default #{@default_ready_timeout_ms}). A server not
      ready before the shared deadline fails open (skipped), as any load failure
      does; N slow servers cost ~timeout total, not N * timeout.
    * `:ready_interval` -- ms between readiness polls (default
      #{@default_ready_interval_ms}).

  Returns `%{tools:, servers:, failed:}`. `servers` are the started client refs
  (the CALLER owns their lifecycle -- supervise or stop them). `failed` lists the
  specs that could not load, with the reason.
  """
  @spec load([server_spec()], keyword()) :: loaded()
  def load(specs, opts \\ []) when is_list(specs) do
    start = Keyword.get(opts, :start, &Raxol.MCP.Client.start_link/1)
    timeout = Keyword.get(opts, :ready_timeout, @default_ready_timeout_ms)
    interval = Keyword.get(opts, :ready_interval, @default_ready_interval_ms)

    # One shared deadline for the whole bundle: clients start concurrently below,
    # so awaiting them against a single absolute deadline bounds total boot delay
    # at ~timeout rather than summing a fresh per-server budget.
    deadline = System.monotonic_time(:millisecond) + timeout

    # Start every client first so their initialize handshakes run concurrently,
    # then await each and list its tools. Start-then-await keeps one server's
    # (multi-second) cold start from serializing the whole bundle's boot.
    specs
    |> Enum.map(&{&1, start_client(&1, start)})
    |> Enum.reduce(%{tools: [], servers: [], failed: []}, fn {spec, started}, acc ->
      name = spec_name(spec)

      case resolve(started, name, deadline, interval, spec) do
        {:ok, server, tools} ->
          %{
            acc
            | tools: acc.tools ++ tools,
              servers: [{name, server} | acc.servers]
          }

        {:error, reason} ->
          Logger.warning(fn ->
            "mcp bundle: server #{inspect(name)} skipped: #{inspect(reason)}"
          end)

          %{acc | failed: [{name, reason} | acc.failed]}
      end
    end)
    |> then(
      &%{
        &1
        | servers: Enum.reverse(&1.servers),
          failed: Enum.reverse(&1.failed)
      }
    )
  end

  # Never `Map.get(spec, :name, spec)`: a nameless spec would then ride into a
  # log line and a `failed` entry carrying its own `:env`/`:headers` values.
  defp spec_name(spec) when is_map(spec), do: Map.get(spec, :name) || :unnamed
  defp spec_name(_spec), do: :unnamed

  defp start_client(spec, start) do
    case transport(spec) do
      :stdio ->
        guarded(start,
          name: spec_name(spec),
          command: Map.fetch!(spec, :command),
          args: Map.get(spec, :args, []),
          env: Map.get(spec, :env, [])
        )

      :remote ->
        start_remote(spec, start)

      {:invalid, why} ->
        {:error, {:invalid_spec, %{name: spec_name(spec), reason: why}}}
    end
  end

  # A client that RAISES or EXITS rather than returning an error puts the opts
  # it was handed inside the reason, and those opts carry resolved header
  # values and env values. Keep the kind and the exception module, drop the
  # message: no credential may ride the `failed` entry or the log line `load/2`
  # writes from it. Containing it here also keeps the fail-open per server,
  # where an escaping exit would have taken the whole bundle's load with it.
  defp guarded(start, opts) do
    start.(opts)
  rescue
    error -> {:error, {:start_raised, error.__struct__}}
  catch
    kind, _reason -> {:error, {:start_raised, kind}}
  end

  # `:command` XOR `:url`. Both is ambiguous and neither is not a server, and
  # guessing either way would start something the operator did not declare.
  defp transport(spec) when is_map(spec) do
    case {is_binary(Map.get(spec, :command)), is_binary(Map.get(spec, :url))} do
      {true, false} -> :stdio
      {false, true} -> :remote
      {true, true} -> {:invalid, :command_and_url}
      {false, false} -> {:invalid, :no_command_or_url}
    end
  end

  defp transport(_spec), do: {:invalid, :not_a_spec}

  # Headers are resolved HERE, once, at connect time: the client never sees a
  # reference and never resolves one. A refusal carries the header name and a
  # classified reason, never a resolved value.
  defp start_remote(spec, start) do
    name = spec_name(spec)
    headers = Map.get(spec, :headers, [])

    case McpHeaders.resolve(headers, source: Map.get(spec, :source, :workspace), server: name) do
      {:ok, resolved} -> guarded(start, remote_opts(spec, name, resolved))
      {:error, _reason} = err -> err
    end
  end

  # `:metered` and `:prices` travel to the transport as well as onto the tools:
  # the hook makes the reservation and the transport enforces it, and a
  # transport that never learned the prices cannot refuse an unmetered call on
  # the path that bypasses the hook.
  defp remote_opts(spec, name, headers) do
    opts = [
      name: name,
      url: Map.fetch!(spec, :url),
      headers: headers,
      metered: Map.get(spec, :metered, false),
      prices: Map.get(spec, :prices, %{})
    ]

    case Map.get(spec, :concurrency) do
      nil -> opts
      policy -> Keyword.put(opts, :concurrency, policy)
    end
  end

  defp resolve({:ok, server}, name, deadline, interval, spec) do
    case poll_tools(server, name, deadline, interval, spec) do
      {:ok, tools} -> {:ok, server, tools}
      {:error, _} = err -> err
    end
  end

  defp resolve({:error, _} = err, _name, _deadline, _interval, _spec), do: err

  # Retry listing tools while the client is still initializing, until ready or
  # the shared deadline. Any non-`:not_ready` error fails open immediately. A
  # server's own `:sensitive` flag (default true) is stamped onto its tools so
  # the ToolConverter authorizer gates them appropriately.
  defp poll_tools(server, name, deadline, interval, spec) do
    sensitive = Map.get(spec, :sensitive, true)

    case list_tools(server, name, sensitive) do
      {:ok, tools} ->
        {:ok, meter(tools, spec)}

      # Only `:starting`/`:initializing` are transient; a `:closed` server has
      # exited and will never become ready, so fail open at once rather than
      # burning the whole budget on a dead port.
      {:error, {:not_ready, status}} = err
      when status in [:starting, :initializing] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(interval)
          poll_tools(server, name, deadline, interval, spec)
        else
          err
        end

      {:error, _} = err ->
        err
    end
  end

  # A client that crashed after start_link (a missing npx/uvx binary dies in
  # handle_continue, past the start return) makes the listing call EXIT with
  # :noproc rather than return an error. Absorb it so fail-open stays
  # per-server instead of taking the whole bundle load down.
  defp list_tools(server, name, sensitive) do
    Dynamic.from_client(server, name, sensitive: sensitive)
  catch
    :exit, reason -> {:error, {:client_down, reason}}
  end

  # Stamp the declared per-call price and the metered origin onto each tool.
  # A tool with a price is sensitive whatever the spec said: an operator can
  # waive the capability gate on a free server, not on one that bills.
  defp meter(tools, spec) do
    prices = Map.get(spec, :prices, %{})
    origin = if Map.get(spec, :metered, false), do: origin(spec), else: nil

    if prices == %{} and is_nil(origin) do
      tools
    else
      Enum.map(tools, &priced(&1, prices, origin))
    end
  end

  defp priced(%Dynamic{} = tool, prices, origin) do
    price = Map.get(prices, raw_name(tool.name))

    %{tool | price: price, origin: origin, sensitive: tool.sensitive or not is_nil(price)}
  end

  # `scheme://host` only. The path and query of a per-account URL are the
  # credential, and this string is built to be logged.
  defp origin(spec) do
    case URI.parse(Map.get(spec, :url, "")) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
        "#{scheme}://#{host}"

      _unparsable ->
        # Still metered, so it must still deny an unpriced tool: name the
        # server rather than fall back to nil, which would read as free.
        "server #{spec_name(spec)}"
    end
  end

  # Prices are declared under the server's own tool names; a bundled tool
  # carries the namespaced one.
  defp raw_name(name) do
    case Raxol.MCP.Client.parse_tool_name(name) do
      {:ok, {_server, tool}} -> tool
      :error -> name
    end
  end

  # Exact versions for the default catalog. `npx`/`uvx` otherwise resolve
  # "latest" at boot and fetch-and-run whatever the registry serves right then,
  # which is unpinned remote code execution in a credential-holding runtime. Pin
  # every server so a boot is reproducible and a poisoned "latest" cannot slip
  # in; bump these deliberately. Verify against the npm/PyPI registries on bump.
  @fs_version "2026.7.10"
  @seq_version "2026.7.4"
  @fetch_version "2026.7.10"
  @git_version "2026.7.10"
  @time_version "2026.7.10"

  @doc """
  The recommended default server catalog.

  `:workspace` scopes the filesystem server's allowed root (default `"."`).
  `npx` / `uvx` must be on PATH at runtime; a missing one fails open (that server
  is skipped, per `load/2`). Every server is version-pinned (see the module
  attributes) so boot never fetches an unpinned "latest".

  Sensitivity reflects capability: filesystem (writes), fetch (arbitrary network
  / SSRF), and git are `sensitive: true`, so the default `deny_sensitive`
  authorizer gates them until an operator opts in. `time` and
  `sequential_thinking` are pure/read-only and stay callable by default.
  """
  @spec default_servers(keyword()) :: [server_spec()]
  def default_servers(opts \\ []) do
    workspace = Keyword.get(opts, :workspace, ".")

    [
      %{
        name: :filesystem,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem@#{@fs_version}", workspace],
        sensitive: true
      },
      %{
        name: :fetch,
        command: "uvx",
        args: ["mcp-server-fetch@#{@fetch_version}"],
        sensitive: true
      },
      %{name: :git, command: "uvx", args: ["mcp-server-git@#{@git_version}"], sensitive: true},
      %{
        name: :time,
        command: "uvx",
        args: ["mcp-server-time@#{@time_version}"],
        sensitive: false
      },
      %{
        name: :sequential_thinking,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-sequential-thinking@#{@seq_version}"],
        sensitive: false
      }
    ]
  end
end
