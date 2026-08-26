defmodule Raxol.Headless.McpTools do
  @moduledoc """
  MCP tool definitions for Raxol headless sessions.

  Registers `raxol_start`, `raxol_screenshot`, `raxol_send_key`,
  `raxol_get_model`, `raxol_stop`, and `raxol_list` as MCP tools
  via `Raxol.MCP.Registry`.
  """

  @doc """
  Returns the list of Raxol MCP tool definitions.
  """
  @spec tools() :: [Raxol.MCP.Registry.tool_def()]
  def tools do
    [
      %{
        name: "raxol_start",
        description: """
        Starts a headless Raxol session. Accepts either a module name
        (atom) or a file path to an example script. Returns the session ID.

        Examples:
          {"module": "RaxolDemo"}
          {"path": "examples/demo.exs", "id": "demo"}
          {"module": "RaxolDemo", "width": 120, "height": 40}
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            module: %{
              type: "string",
              description:
                "Module name as a string (e.g. \"RaxolDemo\"). Mutually exclusive with path."
            },
            path: %{
              type: "string",
              description:
                "Script path RELATIVE to the configured headless path root, e.g. " <>
                  "\"examples/demo.exs\". Disabled unless RAXOL_HEADLESS_PATH_ROOT " <>
                  "(or config :raxol, :headless_path_root) is set, because starting " <>
                  "from a path compiles the file. Mutually exclusive with module."
            },
            id: %{
              type: "string",
              description:
                "Session identifier (default: derived from module name)"
            },
            width: %{
              type: "integer",
              description: "Screen width in columns (default: 120)"
            },
            height: %{
              type: "integer",
              description: "Screen height in rows (default: 40)"
            }
          }
        },
        callback: &start_session/1
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
        Sends a keystroke to a headless Raxol session and returns the
        updated screen content. Supports character keys ("q", "j", " "),
        special keys ("tab", "enter", "escape", "backspace", "up", "down",
        "left", "right"), and modifiers (ctrl, alt, shift).

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
            },
            wait_ms: %{
              type: "integer",
              description:
                "Milliseconds to wait for dispatch processing before screenshot (default: 50)"
            }
          }
        },
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
  Register all headless tools with the given MCP Registry.

  Called from `Raxol.Application` after the MCP supervisor and Headless
  are both running.
  """
  @spec register(GenServer.server()) :: :ok
  def register(registry \\ Raxol.MCP.Registry) do
    if Code.ensure_loaded?(Raxol.MCP.Registry) do
      Raxol.MCP.Registry.register_tools(registry, tools())
    else
      :ok
    end
  end

  @doc """
  Injects Raxol tools into Tidewave's ETS-based tool registry.

  Call after Tidewave.MCP has initialized (typically from Application.start).
  Safe to call multiple times -- tools are merged, not duplicated.

  The Tidewave ETS table is `:protected`, so the insert must run in the
  owning process. We spawn a task linked to that process to do the write.
  """
  @spec inject_into_tidewave() ::
          :ok
          | {:error,
             :inject_timeout
             | :tidewave_not_started
             | :tidewave_owner_not_alive
             | {:sys_replace_failed, term()}}
  def inject_into_tidewave do
    if :ets.whereis(:tidewave_tools) != :undefined do
      owner = :ets.info(:tidewave_tools, :owner)

      if owner && Process.alive?(owner) do
        do_inject(owner)
      else
        {:error, :tidewave_owner_not_alive}
      end
    else
      {:error, :tidewave_not_started}
    end
  end

  defp do_inject(owner) do
    # The ETS table is :protected so only the owner can write.
    # We use :erpc to run the insert in the owning process's context.
    # Since we're on the same node, this is safe and synchronous.
    ref = make_ref()
    me = self()

    # Send a function to the owner process via a monitored intermediary
    # Since the owner is a Supervisor, it handles :code_change but not
    # arbitrary calls. Use :sys.replace_state to safely inject.
    try do
      :sys.replace_state(owner, fn sup_state ->
        do_ets_inject()
        send(me, {:inject_done, ref})
        sup_state
      end)

      receive do
        {:inject_done, ^ref} -> :ok
      after
        5_000 -> {:error, :inject_timeout}
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
  defp do_ets_inject do
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

    new_dispatch =
      Map.merge(
        filtered_dispatch,
        Map.new(our_tools, fn t -> {t.name, t.callback} end)
      )

    :ets.insert(
      :tidewave_tools,
      {:tools,
       {filtered_tools ++ our_tools, new_dispatch, browser_tools,
        browser_dispatch}}
    )
  end

  # --- Tool Callbacks ---

  defp start_session(args) do
    case resolve_module_or_path(args) do
      {:ok, module_or_path} ->
        id = parse_session_id(args["id"])
        width = Map.get(args, "width", 120)
        height = Map.get(args, "height", 40)
        opts = build_start_opts(id, width, height)
        do_start(module_or_path, opts)

      # Already a human-readable sentence, unlike the `inspect`ed terms the other
      # callbacks report.
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_start(module_or_path, opts) do
    case Raxol.Headless.start(module_or_path, opts) do
      {:ok, session_id} -> {:ok, "Session started: #{session_id}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp parse_session_id(nil), do: nil

  defp parse_session_id(id_string) do
    case safe_to_atom(id_string) do
      {:error, _} -> nil
      atom -> atom
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
        |> maybe_add_int(args, "wait_ms", :wait_ms)

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

  defp with_session(args, fun) do
    case safe_to_atom(args["id"]) do
      {:error, _} = err -> {:error, inspect(err)}
      id -> fun.(id)
    end
  end

  # `"module"` arrives from an MCP client, and atoms are never garbage collected:
  # minting one per distinct string lets a caller looping on a wrong name grow the
  # atom table until the VM aborts. `Raxol.Application` registers these tools at
  # startup, so this is a reachable surface rather than a dev-only one.
  #
  # But the atom table alone answers the wrong question. Under `mix mcp.server`
  # the VM loads code on demand, so a module that is compiled and sitting on the
  # code path has no atom until something reaches for it -- and reaching for it
  # is precisely what this tool is asked to do. So the code path decides, and the
  # atom is minted only once a beam file for that exact name is found there:
  # bounded by what is on disk, not by what a caller can type.
  defp resolve_module_or_path(%{"module" => mod}) when is_binary(mod) do
    case existing_module(mod) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        {:error, "unknown module #{inspect(mod)}: it is not loaded in this VM"}
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

  # `:code.where_is_file/1` walks the code path for the beam, which is what
  # `Code.ensure_loaded?/1` would have to find anyway -- asking first just means
  # a name that exists nowhere never becomes an atom.
  defp existing_module(name) do
    prefixed = "Elixir." <> name

    case atom_if_exists(prefixed) do
      {:ok, module} -> {:ok, module}
      :error -> beam_on_code_path(prefixed)
    end
  end

  defp atom_if_exists(prefixed) do
    {:ok, String.to_existing_atom(prefixed)}
  rescue
    ArgumentError -> :error
  end

  # The mint stays bounded because the file has to be there: `where_is_file/1`
  # appends the name to each code-path directory and stats it, so the reachable
  # set is the beams already on disk, which a caller supplying names cannot
  # grow. The `Elixir.` prefix leads, so a separator-bearing name looks for a
  # directory literally called `Elixir.<something>` and finds nothing.
  defp beam_on_code_path(prefixed) do
    case :code.where_is_file(String.to_charlist(prefixed <> ".beam")) do
      :non_existing -> :error
      _path -> {:ok, String.to_atom(prefixed)}
    end
  end

  defp confine_path(root, path) do
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

  defp build_start_opts(nil, width, height), do: [width: width, height: height]

  defp build_start_opts(id, width, height),
    do: [id: id, width: width, height: height]

  defp maybe_add(opts, args, json_key, opt_key) do
    if Map.get(args, json_key, false), do: [{opt_key, true} | opts], else: opts
  end

  defp maybe_add_int(opts, args, json_key, opt_key) do
    case Map.get(args, json_key) do
      nil -> opts
      val when is_integer(val) -> [{opt_key, val} | opts]
      _ -> opts
    end
  end

  defp safe_to_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> {:error, {:unknown_session, str}}
  end
end
