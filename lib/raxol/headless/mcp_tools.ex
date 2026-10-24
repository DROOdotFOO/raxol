defmodule Raxol.Headless.McpTools do
  @moduledoc """
  MCP tool definitions for Raxol headless sessions.

  Registers `raxol_start`, `raxol_screenshot`, `raxol_send_key`,
  `raxol_get_model`, `raxol_stop`, and `raxol_list` as MCP tools
  via `Raxol.MCP.Registry`.

  ## Authorization

  The three tools that change something -- `raxol_start`, `raxol_send_key`,
  `raxol_stop` -- are annotated sensitive, so `Raxol.MCP.Server` refuses to run
  them when no authorizer is configured. So is `raxol_get_model`, a read that
  returns the whole model: an app keeps its secrets there, a masked input's
  plaintext included. `raxol_screenshot` (which draws a masked input as its
  mask) and `raxol_list` are not gated.

  The annotation is only half of it: it does nothing until an authorizer exists
  at the call site, and denies permanently if one never does. `Raxol.Application`
  supplies one (`config :raxol, :mcp_authorizer`, defaulting to `allow_all/0`
  outside production and to a deny-by-default allowlist in production), which is
  what makes these annotations meaningful rather than merely restrictive.

  Both entry points land on that same gate. `register/1` is the ordinary one;
  `inject_into_tidewave/1` routes through `Raxol.MCP.Server` as well rather than
  handing Tidewave the raw callbacks, so neither surface can drift from the
  policy the other enforces.

  ## Startable modules

  A `"module"` argument starts only a module on `startable/0`. That is
  `config :raxol, :headless_startable` when it is set, and otherwise the
  playground demos except `Raxol.Playground.Demos.ReplDemo` (it evaluates
  Elixir) and `Raxol.Playground.Demos.BeamDashboardDemo` (it sets the
  VM-wide `:scheduler_wall_time` flag and shows VM internals). A set list
  REPLACES the demos, so a deployment names exactly what clients may start
  by module:

      config :raxol, :headless_startable, [MyApp]

  To keep the demos as well, list them too (`default_startable/0` returns
  them). Every entry must be a loadable module (`Code.ensure_loaded?/1`):
  `register/1` raises on a value that is not, so a bad config stops the boot,
  and a value changed at runtime makes `raxol_start` answer with the same
  config error rather than start anything.

  The list does not bind the `"path"` argument. When a deployment sets
  `RAXOL_HEADLESS_PATH_ROOT` (or `config :raxol, :headless_path_root`),
  `raxol_start` compiles and starts any module defined in a file under that
  root, listed or not, because the module is only known once the file is
  compiled. Unset, the argument is refused.

  The list binds the MCP tool, which starts a module for an untrusted
  caller. Elixir callers of `Raxol.Headless.start/2` (`Raxol.MCP.Test`,
  `Raxol.Recording.Video`) are trusted and start any Raxol application.
  """

  @startable_config_error "config :raxol, :headless_startable must be a list of loadable modules"

  @never_default_startable [
    Raxol.Playground.Demos.ReplDemo,
    Raxol.Playground.Demos.BeamDashboardDemo
  ]

  @session_id_format ~r/\A[a-z][a-z0-9]{0,6}\z/

  @doc """
  Returns the list of Raxol MCP tool definitions.

  `raxol_start` starts sessions whose derived tools are registered in
  `registry` (default `Raxol.MCP.Registry`), the registry `register/1`
  puts these tools in.
  """
  @spec tools(GenServer.server()) :: [Raxol.MCP.Registry.tool_def()]
  def tools(registry \\ Raxol.MCP.Registry) do
    [
      %{
        name: "raxol_start",
        description: """
        Starts a headless Raxol session from a module name. The module must be
        on this server's startable list (the playground demos unless the
        deployment sets its own) and a Raxol application: it has to export init/1,
        update/2 and view/1.

        A "path" argument also exists, but it is DISABLED unless the deployment
        sets RAXOL_HEADLESS_PATH_ROOT, because starting from a path compiles the
        file. Prefer "module"; the path property below has the details.

        Examples:
          {"module": "Raxol.Playground.Demos.TableDemo", "id": "demo"}
          {"module": "Raxol.Playground.Demos.TableDemo", "id": "t1", "width": 120, "height": 40}
        """,
        inputSchema: %{
          type: "object",
          required: ["id"],
          properties: %{
            module: %{
              type: "string",
              description:
                "Module name as a string (e.g. \"Raxol.Playground.Demos.TableDemo\"). " <>
                  "Mutually exclusive with path."
            },
            path: %{
              type: "string",
              description:
                "Script path RELATIVE to the configured headless path root, e.g. " <>
                  "\"examples/demo.exs\". Disabled unless RAXOL_HEADLESS_PATH_ROOT " <>
                  "(or config :raxol, :headless_path_root) is set, because starting " <>
                  "from a path compiles the file. An absolute path is REFUSED " <>
                  "rather than resolved under the root, so the file that runs is " <>
                  "always the file you named. Mutually exclusive with module."
            },
            id: %{
              type: "string",
              pattern: "^[a-z][a-z0-9]{0,6}$",
              description:
                "Session identifier: 1 to 7 characters, a lowercase letter then " <>
                  "lowercase letters or digits (no underscores or dots)"
            },
            width: %{
              type: "integer",
              minimum: 1,
              maximum: Raxol.Core.Defaults.max_remote_terminal_width(),
              description:
                "Screen width in columns (default: 120). width * height " <>
                  "may not exceed #{Raxol.Core.Defaults.max_remote_terminal_cells()} cells."
            },
            height: %{
              type: "integer",
              minimum: 1,
              maximum: Raxol.Core.Defaults.max_remote_terminal_height(),
              description: "Screen height in rows (default: 40)"
            }
          }
        },
        # Starting a session spawns a supervised process, and where a deployment
        # has set a headless path root the "path" argument reaches the compiler,
        # where compiling a `defmodule` executes its body. `destructiveHint` is
        # the wrong word for that -- nothing is destroyed -- so this uses
        # `sensitive`, raxol_mcp's own flag for a tool that must not run
        # unattended. `Raxol.MCP.ToolDef.sensitive?/1` honours either.
        annotations: %{sensitive: true},
        callback: &start_session(&1, registry),
        fault?: &start_fault?/1
      },
      %{
        name: "raxol_screenshot",
        description: """
        Captures a text screenshot of a running headless Raxol session.
        Returns the current screen content as plain text (no ANSI codes).
        """,
        inputSchema: %{
          type: "object",
          required: ["id"],
          properties: %{
            id: %{
              type: "string",
              description: "Session identifier"
            }
          }
        },
        callback: &screenshot/1
      },
      %{
        name: "raxol_send_key",
        description: """
        Sends a keystroke to a headless Raxol session and returns the screen
        once the app has handled the key. Supports character keys ("q", "j",
        " "), special keys ("tab", "enter", "escape", "backspace", "up",
        "down", "left", "right"), and modifiers (ctrl, alt, shift).
        Results of asynchronous work the key starts (a background task, a
        timer) may only show on a later raxol_screenshot.

        Examples:
          {"id": "demo", "key": "tab"}
          {"id": "demo", "key": "q"}
          {"id": "demo", "key": "c", "ctrl": true}
        """,
        inputSchema: %{
          type: "object",
          required: ["id", "key"],
          properties: %{
            id: %{
              type: "string",
              description: "Session identifier"
            },
            key: %{
              type: "string",
              description:
                "Key to send: a character (\"q\", \"j\") or special key name (\"tab\", \"enter\", \"escape\", \"up\", \"down\", \"left\", \"right\", \"backspace\")"
            },
            ctrl: %{
              type: "boolean",
              description: "Hold Ctrl modifier (default: false)"
            },
            alt: %{
              type: "boolean",
              description: "Hold Alt modifier (default: false)"
            },
            shift: %{
              type: "boolean",
              description: "Hold Shift modifier (default: false)"
            }
          }
        },
        # A keystroke is the session's whole input surface: whatever the running
        # app does on a key, this tool can cause. It is not destructive on its
        # own, so `sensitive` rather than `destructiveHint`.
        annotations: %{sensitive: true},
        callback: &send_key/1
      },
      %{
        name: "raxol_get_model",
        description: """
        Returns the current TEA model (application state) of a headless
        Raxol session as an inspected Elixir term.
        """,
        inputSchema: %{
          type: "object",
          required: ["id"],
          properties: %{
            id: %{
              type: "string",
              description: "Session identifier"
            }
          }
        },
        # The whole model, whatever the app keeps in it: a token, or the
        # plaintext of a masked input the screen draws as its mask.
        annotations: %{sensitive: true},
        callback: &get_model/1
      },
      %{
        name: "raxol_stop",
        description: """
        Stops a running headless Raxol session and frees its resources.
        """,
        inputSchema: %{
          type: "object",
          required: ["id"],
          properties: %{
            id: %{
              type: "string",
              description: "Session identifier"
            }
          }
        },
        # Tears down a running session and its state. Destructive in the plain
        # MCP sense, so it carries the spec's own hint.
        annotations: %{destructiveHint: true},
        callback: &stop_session/1
      },
      %{
        name: "raxol_list",
        description: """
        Lists all active headless Raxol sessions.
        """,
        inputSchema: %{
          type: "object",
          properties: %{}
        },
        callback: &list_sessions/1
      }
    ]
  end

  @doc """
  The modules `raxol_start` may start: `config :raxol, :headless_startable`
  when set (it replaces the default), else `default_startable/0`.

  Answers `{:error, sentence}` when the configured value is not a list of
  loadable modules (`Code.ensure_loaded?/1`, which loads one that is on the
  code path but not loaded yet).
  """
  @spec startable() :: {:ok, [module()]} | {:error, String.t()}
  def startable do
    case Application.fetch_env(:raxol, :headless_startable) do
      :error ->
        {:ok, default_startable()}

      {:ok, modules} when is_list(modules) ->
        if List.improper?(modules),
          do: {:error, invalid_startable(modules)},
          else: loadable_startable(modules)

      {:ok, other} ->
        {:error, invalid_startable(other)}
    end
  end

  defp loadable_startable(modules) do
    case Enum.reject(modules, &(is_atom(&1) and Code.ensure_loaded?(&1))) do
      [] ->
        {:ok, modules}

      unloadable ->
        {:error,
         @startable_config_error <>
           "; these entries are not: " <>
           inspect(unloadable, limit: 10, printable_limit: 200)}
    end
  end

  @doc """
  Every playground demo except `Raxol.Playground.Demos.ReplDemo`, which
  evaluates Elixir, and `Raxol.Playground.Demos.BeamDashboardDemo`, which
  sets the VM-wide `:scheduler_wall_time` flag and shows VM internals: what
  `raxol_start` may start when `config :raxol, :headless_startable` is not
  set.
  """
  @spec default_startable() :: [module()]
  def default_startable do
    for %{module: module} <- Raxol.Playground.Catalog.list_components(),
        module not in @never_default_startable,
        do: module
  end

  defp invalid_startable(value) do
    @startable_config_error <>
      ", got: " <> inspect(value, limit: 10, printable_limit: 200)
  end

  # The config error is the deployment's, not the tool's: counted as a fault,
  # five calls opened `raxol_start`'s circuit for every client, and it stayed
  # open after the config was fixed. Every other error still counts.
  defp start_fault?(reason),
    do:
      not (is_binary(reason) and
             String.starts_with?(reason, @startable_config_error))

  @doc """
  Register all headless tools with the given MCP Registry.

  Called from `Raxol.Application` after the MCP supervisor and Headless
  are both running. Raises `ArgumentError` when
  `config :raxol, :headless_startable` is invalid (see `startable/0`), so a
  bad config stops the boot instead of surfacing at the first `raxol_start`.
  """
  @spec register(GenServer.server()) ::
          :ok | {:error, {:name_collision, [{String.t(), String.t()}]}}
  def register(registry \\ Raxol.MCP.Registry) do
    case startable() do
      {:ok, _modules} -> :ok
      {:error, message} -> raise ArgumentError, message
    end

    if Code.ensure_loaded?(Raxol.MCP.Registry) do
      Raxol.MCP.Registry.register_tools(registry, tools(registry))
    else
      :ok
    end
  end

  @doc """
  Injects Raxol tools into Tidewave's ETS-based tool registry.

  Call after Tidewave.MCP has initialized (typically from Application.start).
  Safe to call multiple times -- tools are merged, not duplicated.

  What is injected is NOT the raw tool callback. Tidewave dispatches straight out
  of its own map, so a callback written there would never reach
  `Raxol.MCP.Server` and no authorizer, annotation, or elicitation would apply to
  it -- the one route that bypasses every gate the rest of this module relies on.
  Each entry is instead a closure that re-enters through `tools/call` on the
  server named by `:server`, so this surface inherits exactly the policy the
  supervisor was started with. If that server is not running, calls are refused
  rather than executed.

  > #### This gates Raxol's tools, not Tidewave's {: .warning}
  >
  > Tidewave's own tools are untouched and ungated by anything here; `project_eval`
  > in particular evaluates Elixir in the running node. Whether that endpoint may
  > be reached at all is an endpoint-level decision (authentication, bind address),
  > not one this function can make.

  The Tidewave ETS table is `:protected`, so the insert must run in the
  owning process. We spawn a task linked to that process to do the write.

  ## Options

    * `:server` -- the MCP server calls are routed through. Defaults to
      `Raxol.MCP.Server`.
  """
  @spec inject_into_tidewave(keyword()) ::
          :ok
          | {:error,
             :inject_timeout
             | :tidewave_not_started
             | :tidewave_owner_not_alive
             | {:sys_replace_failed, term()}}
  def inject_into_tidewave(opts \\ []) do
    server = Keyword.get(opts, :server, Raxol.MCP.Server)

    if :ets.whereis(:tidewave_tools) != :undefined do
      owner = :ets.info(:tidewave_tools, :owner)

      if owner && Process.alive?(owner) do
        do_inject(owner, server)
      else
        {:error, :tidewave_owner_not_alive}
      end
    else
      {:error, :tidewave_not_started}
    end
  end

  # Bounded because `do_inject/2` runs inside `Application.start/2`; see the
  # comment on the waits below.
  @inject_timeout_ms 500

  defp do_inject(owner, server) do
    # The ETS table is :protected so only the owner can write.
    # We use :erpc to run the insert in the owning process's context.
    # Since we're on the same node, this is safe and synchronous.
    ref = make_ref()
    me = self()

    # Send a function to the owner process via a monitored intermediary
    # Since the owner is a Supervisor, it handles :code_change but not
    # arbitrary calls. Use :sys.replace_state to safely inject.
    # Both waits are bounded well under a second. This runs synchronously
    # inside `Application.start/2`, and the pair used to be OTP's default 5s
    # plus another 5s here -- so a slow or wedged Tidewave supervisor added up
    # to ~10s to every dev boot before the failure was downgraded to a debug
    # log. Nothing depends on the result; it is a dev convenience.
    try do
      :sys.replace_state(
        owner,
        fn sup_state ->
          do_ets_inject(server)
          send(me, {:inject_done, ref})
          sup_state
        end,
        @inject_timeout_ms
      )

      receive do
        {:inject_done, ^ref} -> :ok
      after
        @inject_timeout_ms -> {:error, :inject_timeout}
      end
    catch
      :exit, reason -> {:error, {:sys_replace_failed, reason}}
    end
  end

  # Tidewave 0.9.0 widened this record from `{tools, dispatch}` to
  # `{tools, dispatch, browser_tools, browser_dispatch}`. The browser halves are
  # carried through untouched: they are Tidewave's own, and merging our tools
  # into them would offer a browser-only client tools it cannot run.
  #
  # The arity is matched rather than ignored with a trailing `_`. A shape change
  # is exactly what happened here, and it has to fail loudly enough to reach
  # `{:error, {:sys_replace_failed, _}}` rather than write a record Tidewave
  # will later fail to read.
  defp do_ets_inject(server) do
    [
      {:tools,
       {existing_tools, existing_dispatch, browser_tools, browser_dispatch}}
    ] =
      :ets.lookup(:tidewave_tools, :tools)

    our_tools = tools()
    our_names = MapSet.new(our_tools, & &1.name)

    # Remove any previously injected Raxol tools to avoid duplicates
    filtered_tools =
      Enum.reject(existing_tools, &MapSet.member?(our_names, &1.name))

    filtered_dispatch =
      Map.drop(existing_dispatch, Enum.map(our_tools, & &1.name))

    gated =
      Map.new(our_tools, fn t -> {t.name, gated_callback(server, t.name)} end)

    new_dispatch = Map.merge(filtered_dispatch, gated)

    # The ADVERTISED entries carry a `:callback` as well, and only the dispatch
    # map above used to be gated -- so each of the six entries went into
    # Tidewave's table holding its raw capture (`&start_session/1` and
    # friends). Any consumer reaching for `tool.callback` rather than going
    # through the dispatch map bypassed the authorizer, the sensitive-tool
    # gate and elicitation entirely. Substitute in both places: one enforcement
    # point is only true if every copy of the entry point routes through it.
    gated_tools =
      Enum.map(our_tools, fn t ->
        Map.put(t, :callback, Map.fetch!(gated, t.name))
      end)

    :ets.insert(
      :tidewave_tools,
      {:tools,
       {filtered_tools ++ gated_tools, new_dispatch, browser_tools,
        browser_dispatch}}
    )
  end

  # Re-enters through `tools/call` rather than invoking the callback directly, so
  # a Tidewave-dispatched call is subject to the same authorizer, sensitive-tool
  # gate, and elicitation handling as one arriving over stdio or SSE. Routing
  # through the server rather than re-implementing the checks here is the point:
  # there is one enforcement point, and this surface cannot drift from it.
  #
  # A server that is down denies rather than falling back to the raw callback.
  # The fallback is the whole vulnerability -- an ungated path that appears
  # exactly when the gate is unavailable.
  defp gated_callback(server, name) do
    fn args ->
      message = %{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: "tools/call",
        params: %{"name" => name, "arguments" => args}
      }

      case safe_handle_message(server, message) do
        {:reply, %{result: %{content: content, isError: true}}} ->
          {:error, content_text(content)}

        {:reply, %{result: %{content: content}}} ->
          {:ok, content_text(content)}

        {:reply, %{error: %{message: reason}}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}

        other ->
          # Never render an internal server term into a client-facing string.
          Raxol.Core.Runtime.Log.debug(
            "unexpected MCP reply on the Tidewave path: #{inspect(other)}"
          )

          {:error, "the Raxol MCP server returned an unexpected reply"}
      end
    end
  end

  # Its OWN connection id, never the shared default.
  #
  # `Raxol.MCP.Server.handle_message/2` attributes a call to the `:default`
  # connection, which is also what `Transport.Stdio` subscribes as. Sharing it
  # crossed two clients: an `{:ask, _}` decision on a call that arrived here sent
  # the prompt to the STDIO client and let that client's answer resolve THIS
  # call, while Tidewave -- whose request had parked -- got back the server's
  # `nil` placeholder rendered as the string `"{:reply, nil}"`.
  #
  # A distinct id settles it by making the truth checkable. `elicitation_capable?`
  # requires the connection to be subscribed, and Tidewave never subscribes: it
  # dispatches synchronously and has no channel to be asked on. So ASK resolves
  # to a machine-readable deny here, which is the right answer for a caller that
  # cannot be prompted, and no other client is involved.
  @tidewave_conn :tidewave

  # Bounded, unlike stdio and SSE. Tidewave used to invoke the callback in its
  # own request process; routing through the server is right, but inheriting
  # `:infinity` there meant one slow `raxol_screenshot` stalled the stdio
  # client, every SSE client and every other Tidewave request, with nothing
  # able to break it. Long enough for a screenshot of a busy app, short enough
  # that a wedged tool cannot hold the whole surface.
  @tidewave_call_timeout_ms 30_000

  defp safe_handle_message(server, message) do
    Raxol.MCP.Server.handle_message(
      server,
      message,
      @tidewave_conn,
      @tidewave_call_timeout_ms
    )
  catch
    # A crashed server exits with its own reason and must not be reported as an
    # absent one: an operator-supplied authorizer that raises looks identical to
    # "not running" otherwise, and the real fault never surfaces.
    :exit, {:noproc, _} ->
      {:error,
       "the Raxol MCP server is not running, so this call cannot be authorized"}

    :exit, {:timeout, _} ->
      {:error,
       "the Raxol MCP server did not answer within " <>
         "#{@tidewave_call_timeout_ms}ms, so this call was not authorized"}

    :exit, reason ->
      Raxol.Core.Runtime.Log.warning_with_context(
        "Raxol MCP server exited while authorizing a Tidewave call: " <>
          "#{inspect(reason)}",
        %{}
      )

      {:error, "the Raxol MCP server failed while authorizing this call"}
  end

  defp content_text([%{text: text} | _]) when is_binary(text), do: text
  defp content_text([%{"text" => text} | _]) when is_binary(text), do: text
  defp content_text(other), do: inspect(other)

  # --- Tool Callbacks ---

  defp start_session(args, registry) do
    # Both refusals are already human-readable sentences, unlike the
    # `inspect`ed terms the other callbacks report.
    with {:ok, id} <- session_id(args),
         {:ok, module_or_path} <- resolve_module_or_path(args),
         {:ok, {width, height}} <- start_size(args) do
      do_start(module_or_path,
        id: id,
        width: width,
        height: height,
        registry: registry
      )
    end
  end

  # The id is to name every tool the session derives (`<id>.<widget>.<action>`,
  # and a client renames those: OMP turns each `.` into `_` and prefixes the
  # 17-character `mcp__raxol_raxol_`. No `_` or `.` in the id keeps the
  # session boundary unambiguous after that rename (`a_b.c` and `a.b_c` would
  # both become `a_b_c`), and 7 characters leave the longest demo widget and
  # action within OMP's 64. Refused, never replaced: a caller that named a
  # session must not find its tools under another name.
  defp session_id(%{"id" => id}) when is_binary(id) do
    if Regex.match?(@session_id_format, id),
      do: {:ok, id},
      else: {:error, id_refusal(id)}
  end

  defp session_id(%{"id" => id}), do: {:error, id_refusal(id)}

  defp session_id(_args),
    do: {:error, "'id' is required: " <> id_rule()}

  defp id_refusal(id), do: "session id #{inspect(id)} is refused: " <> id_rule()

  defp id_rule,
    do:
      "1 to 7 characters, a lowercase letter then lowercase letters or digits " <>
        "(no underscores or dots)"

  # Refused, not clamped: the caller named this size, so it is told the range
  # rather than handed a smaller screen than it asked for. The ceiling is the
  # remote one, as for SSH: an MCP client is on the other end of a network
  # surface, and each call it makes draws a frame of this size. SSH clamps to
  # the same ceiling instead (a window is not a request it can re-issue).
  defp start_size(args) do
    width = Map.get(args, "width", 120)
    height = Map.get(args, "height", 40)

    case Raxol.Core.Utils.Validation.validate_terminal_size(
           width,
           height,
           Raxol.Core.Defaults.remote_terminal_size_ceiling()
         ) do
      :ok ->
        {:ok, {width, height}}

      {:error, _reason} ->
        {:error,
         "width and height must be positive integers, width at most " <>
           "#{Raxol.Core.Defaults.max_remote_terminal_width()}, height at most " <>
           "#{Raxol.Core.Defaults.max_remote_terminal_height()}, and width * height " <>
           "at most #{Raxol.Core.Defaults.max_remote_terminal_cells()} cells; " <>
           "got #{inspect(width)}x#{inspect(height)}"}
    end
  end

  defp do_start(module_or_path, opts) do
    case Raxol.Headless.start(module_or_path, opts) do
      {:ok, session_id} ->
        {:ok, "Session started: #{session_id}"}

      # Spelled out rather than `inspect`ed because this is the refusal an
      # operator is most likely to hit by naming a real module that simply is
      # not an app, and the tuple alone does not say what the contract IS.
      {:error, {:not_a_raxol_application, module}} ->
        {:error,
         "#{inspect(module)} exists but is not a Raxol application: it neither " <>
           "declares Raxol.Core.Runtime.Application nor exports init/1, " <>
           "update/2 and view/1"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp screenshot(args) do
    with_session(args, fn id ->
      case Raxol.Headless.screenshot(id) do
        {:ok, text} -> {:ok, text}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end)
  end

  defp send_key(args) do
    with_session(args, fn id ->
      key = parse_key(args["key"])

      opts =
        []
        |> maybe_add(args, "ctrl", :ctrl)
        |> maybe_add(args, "alt", :alt)
        |> maybe_add(args, "shift", :shift)

      case Raxol.Headless.send_key_and_screenshot(id, key, opts) do
        {:ok, text} -> {:ok, text}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end)
  end

  defp get_model(args) do
    with_session(args, fn id ->
      case Raxol.Headless.get_model(id) do
        {:ok, model} -> {:ok, inspect(model, pretty: true, limit: 100)}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end)
  end

  defp stop_session(args) do
    with_session(args, fn id ->
      case Raxol.Headless.stop(id) do
        :ok -> {:ok, "Session #{id} stopped."}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end)
  end

  defp list_sessions(_args) do
    sessions = Raxol.Headless.list()

    if sessions == [] do
      {:ok, "No active sessions."}
    else
      {:ok, "Active sessions: #{Enum.map_join(sessions, ", ", &to_string/1)}"}
    end
  end

  # --- Helpers ---

  # The id is passed through as the binary it arrived as; an unknown one is
  # Headless's `:not_found`, and no atom is made from it.
  defp with_session(%{"id" => id}, fun) when is_binary(id), do: fun.(id)

  defp with_session(_args, _fun),
    do: {:error, "'id' is required and must be a string"}

  # `"module"` arrives from an MCP client, which is choosing what this VM runs,
  # so it is matched by name against `startable/0` before anything resolves it.
  # An unlisted name is refused without a code-path lookup and without minting
  # an atom (atoms are never collected); a listed one is already an atom, and
  # `startable/0` has loaded it. A broken list is the config error, answered
  # as the tool's error rather than raised.
  defp resolve_module_or_path(%{"module" => _mod, "path" => _path}),
    do: {:error, "'module' and 'path' are mutually exclusive"}

  defp resolve_module_or_path(%{"module" => mod}) when is_binary(mod) do
    prefixed = "Elixir." <> mod

    with {:ok, modules} <- startable() do
      case Enum.find(modules, &(Atom.to_string(&1) == prefixed)) do
        nil ->
          {:error,
           "module #{inspect(mod)} is not startable over MCP: only the modules in " <>
             "config :raxol, :headless_startable are (when unset, the playground " <>
             "demos except ReplDemo and BeamDashboardDemo)"}

        module ->
          {:ok, module}
      end
    end
  end

  # Starting from a path is ARBITRARY CODE EXECUTION, not a file read.
  # `Raxol.Headless.start/2` runs the file through `Code.compile_quoted/2`, and
  # compiling a `defmodule` executes its body -- so whoever chooses this string
  # chooses what runs in this VM. The AST filter that keeps only `defmodule`
  # nodes is a convenience (it skips an example's boot code), never a sandbox.
  #
  # So the branch is off unless a deployment opts in by naming a root, and the
  # candidate is confined under it. Unset is the default, and it REFUSES rather
  # than falling back to the cwd: an MCP server's working directory is not a
  # security boundary anyone chose.
  #
  # Containment is `Raxol.Core.Boundary.Path.confine/3`, the repo's shared
  # primitive -- lexical check, then a real-path resolution of BOTH sides, then a
  # re-check, so a symlink pointing out of the root is refused rather than
  # followed. Deciding this on the lexical path alone is the bug it exists to
  # prevent. `:ref_format` additionally requires an Elixir extension, since a
  # path that cannot be compiled has no business reaching the compiler.
  #
  # Note `confine/3` joins the request under the root, so an ABSOLUTE path is
  # jailed rather than honoured. That is the intent, and it costs nothing: the
  # documented use (`examples/demo.exs`) was always relative.
  defp resolve_module_or_path(%{"path" => path}) when is_binary(path) do
    case headless_path_root() do
      nil ->
        {:error,
         "starting from a path is disabled: it compiles the file, which executes " <>
           "module bodies. Set RAXOL_HEADLESS_PATH_ROOT (or config :raxol, " <>
           ":headless_path_root) to the directory scripts may be started from."}

      root ->
        confine_path(root, path)
    end
  end

  # Deliberately does NOT mention 'path'. That branch compiles whatever it is
  # given, so steering a caller who fat-fingered a module name onto it would
  # trade a refused lookup for something much worse.
  defp resolve_module_or_path(_),
    do: {:error, "Either 'module' or 'path' is required"}

  # An absolute path is REFUSED here rather than left to `confine/3`.
  #
  # `confine/3` is safe either way: it does `Path.join(root, requested)`, so
  # `/etc/evil.exs` is jailed to `<root>/etc/evil.exs` and never honoured. But
  # jailing it means the tool compiles a DIFFERENT file than the one it was
  # asked for and says nothing, and the schema already documents this argument
  # as relative to the root. For an argument whose whole job is choosing which
  # code executes, answering a different file silently is the worse of the two
  # available behaviours -- so the mismatch is named instead.
  #
  defp confine_path(root, path) when is_binary(path) and path != "" do
    case anchored_kind(path) do
      nil -> do_confine_path(root, path)
      kind -> {:error, absolute_refusal(path, kind)}
    end
  end

  defp confine_path(_root, path) when is_binary(path),
    do: {:error, "path must not be empty"}

  # `nil` for a genuinely relative path; otherwise what it is anchored at.
  #
  # `Path.type/1` alone is not enough, because it is OS-dependent in exactly the
  # direction that hurts: on Unix `Path.type("c:/x")` is `:relative`, so the
  # same argument would be refused on Windows and rewritten under the root on
  # Unix. `Raxol.Core.Boundary.Path` settled this question one layer down --
  # a drive or UNC anchor counts on EVERY host, because one rule erring toward
  # refusal beats two rules disagreeing about the same string -- and this
  # mirrors it rather than inventing a second answer.
  defp anchored_kind(path) do
    cond do
      Path.type(path) != :relative -> Path.type(path)
      drive_anchored?(path) -> :drive_absolute
      unc_anchored?(path) -> :unc_absolute
      true -> nil
    end
  end

  defp drive_anchored?(<<letter, ?:, _::binary>>)
       when letter in ?A..?Z or letter in ?a..?z,
       do: true

  defp drive_anchored?(_), do: false

  defp unc_anchored?(<<sep, sep, _::binary>>) when sep in [?/, ?\\], do: true
  defp unc_anchored?(_), do: false

  defp absolute_refusal(path, kind) do
    "path must be RELATIVE to the configured headless path root, and " <>
      "#{inspect(path)} is #{kind}. It would be jailed under the root rather " <>
      "than honoured, so the file that ran would not be the file you named. " <>
      "Drop the leading separator or drive."
  end

  defp do_confine_path(root, path) do
    case Raxol.Core.Boundary.Path.confine(root, path, ref_format: ~r/\.exs?$/) do
      {:ok, real} ->
        {:ok, real}

      {:error, :malformed_ref} ->
        {:error, "path must name an .ex or .exs file"}

      {:error, reason} ->
        {:error,
         "path is outside the configured headless path root (#{reason})"}
    end
  end

  defp headless_path_root do
    case System.get_env("RAXOL_HEADLESS_PATH_ROOT") do
      root when is_binary(root) and root != "" -> root
      _ -> Application.get_env(:raxol, :headless_path_root)
    end
  end

  @special_keys ~w(tab enter escape backspace up down left right home end page_up page_down delete insert f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12)

  defp parse_key(key) when key in @special_keys, do: String.to_atom(key)
  defp parse_key(key) when is_binary(key), do: key

  defp maybe_add(opts, args, json_key, opt_key) do
    if Map.get(args, json_key, false), do: [{opt_key, true} | opts], else: opts
  end
end
