defmodule Raxol.MCP.Test do
  @moduledoc """
  Test harness for Raxol MCP applications.

  Provides session management, semantic interaction helpers, and a
  pipe-friendly API for testing apps via their MCP tool interface.

  ## Usage

      import Raxol.MCP.Test
      import Raxol.MCP.Test.Assertions

      test "user can search" do
        session = start_session(MyApp)

        session
        |> type_into("search_input", "elixir")
        |> click("search_btn")
        |> assert_component("results_table", fn c -> c[:content] != nil end)
        |> stop_session()
      end

  ## How It Works

  `start_session/2` spins up a headless TEA module (via `Raxol.Headless`),
  a per-session `Raxol.MCP.Registry`, and a `ToolSynchronizer` that
  auto-derives MCP tools from the view tree. Interaction helpers like
  `click/2` and `type_into/3` call tools through the registry, exercising
  the full MCP pipeline.

  For unit tests that don't need a running app, use the lower-level
  modules directly: `TreeWalker.derive_tools/2`, `Registry.call_tool/3`.
  """

  @compile {:no_warn_undefined,
            [
              Raxol.Headless,
              Raxol.Headless.EventBuilder
            ]}

  alias Raxol.MCP.Test.Session
  alias Raxol.MCP.Registry
  alias Raxol.MCP.StructuredScreenshot

  @default_settle_ms 100

  # -- Session Lifecycle -------------------------------------------------------

  @doc """
  Start a headless MCP test session for the given TEA module.

  Returns a `%Session{}` struct that flows through all pipe-friendly helpers.

  ## Options

    * `:id` - session ID (default: auto-generated unique atom)
    * `:width` - terminal width (default: 120)
    * `:height` - terminal height (default: 40)
    * `:settle_ms` - ms to wait after start for initial render (default: #{@default_settle_ms})
  """
  @spec start_session(module() | String.t(), keyword()) :: Session.t()
  def start_session(module_or_path, opts \\ []) do
    unique = System.unique_integer([:positive])
    session_id = Keyword.get(opts, :id, :"test_#{unique}")
    registry_name = :"test_registry_#{unique}"
    settle_ms = Keyword.get(opts, :settle_ms, @default_settle_ms)

    {:ok, registry_pid} = Registry.start_link(name: registry_name)

    headless_opts =
      opts
      |> Keyword.merge(id: session_id, registry: registry_name)
      |> Keyword.drop([:settle_ms])

    if Code.ensure_loaded?(Raxol.Headless) do
      {:ok, ^session_id} = Raxol.Headless.start(module_or_path, headless_opts)
    else
      raise "Raxol.Headless is required but not available. " <>
              "Add {:raxol, path: \"..\"} as a test dependency."
    end

    Process.sleep(settle_ms)

    %Session{
      id: session_id,
      registry: registry_name,
      registry_pid: registry_pid,
      module: module_or_path,
      settle_ms: settle_ms
    }
  end

  @doc """
  Stop a test session, cleaning up all resources.

  Returns `:ok`. Can be used at the end of a pipe (the session is consumed).
  """
  @spec stop_session(Session.t()) :: :ok
  def stop_session(%Session{} = session) do
    if Code.ensure_loaded?(Raxol.Headless) do
      try do
        Raxol.Headless.stop(session.id)
      catch
        :exit, _ -> :ok
      end
    end

    try do
      GenServer.stop(session.registry_pid)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  # -- Pipe-Friendly Interaction Helpers ---------------------------------------

  @doc """
  Click a Button Component by ID.

  Calls the `component_id.click` tool through the MCP registry.

      session |> click("submit_btn")
  """
  @spec click(Session.t(), String.t()) :: Session.t()
  def click(%Session{} = session, component_id) do
    call_tool!(session, "#{component_id}.click", %{})
  end

  @doc """
  Type text into an input Component by ID.

  Calls the `component_id.type_into` tool through the MCP registry.

      session |> type_into("search_input", "elixir")
  """
  @spec type_into(Session.t(), String.t(), String.t()) :: Session.t()
  def type_into(%Session{} = session, component_id, text) do
    call_tool!(session, "#{component_id}.type_into", %{"text" => text})
  end

  @doc """
  Clear an input Component by ID.

  Calls the `component_id.clear` tool through the MCP registry.

      session |> clear("search_input")
  """
  @spec clear(Session.t(), String.t()) :: Session.t()
  def clear(%Session{} = session, component_id) do
    call_tool!(session, "#{component_id}.clear", %{})
  end

  @doc """
  Select a row in a table or item in a list by ID.

      session |> select("results_table", %{"index" => 0})
  """
  @spec select(Session.t(), String.t(), map()) :: Session.t()
  def select(%Session{} = session, component_id, args \\ %{}) do
    call_tool!(session, "#{component_id}.select_row", args)
  end

  @doc """
  Toggle a checkbox by ID.

      session |> toggle("remember_me")
  """
  @spec toggle(Session.t(), String.t()) :: Session.t()
  def toggle(%Session{} = session, component_id) do
    call_tool!(session, "#{component_id}.toggle", %{})
  end

  @doc """
  Call an arbitrary MCP tool by its full name.

  Returns the session for piping. Raises on failure.

      session |> call_tool("component_id.action", %{"key" => "value"})
  """
  @spec call_tool(Session.t(), String.t(), map()) :: Session.t()
  def call_tool(%Session{} = session, tool_name, args \\ %{}) do
    call_tool!(session, tool_name, args)
  end

  @doc """
  Send a key event to the session via Headless.

  This bypasses MCP tools -- use for navigation (Tab, Escape, arrow keys)
  that don't map to Component tools.

      session |> send_key(:tab) |> send_key("q", ctrl: true)
  """
  @spec send_key(Session.t(), atom() | String.t(), keyword()) :: Session.t()
  def send_key(%Session{} = session, key, opts \\ []) do
    if Code.ensure_loaded?(Raxol.Headless) do
      Raxol.Headless.send_key(session.id, key, opts)
    end

    Process.sleep(session.settle_ms)
    session
  end

  @doc """
  Send a sequence of key events.

      session |> send_keys([:tab, :tab, :enter])
      session |> send_keys([{"a", ctrl: true}, :escape])
  """
  @spec send_keys(Session.t(), [atom() | String.t() | {atom() | String.t(), keyword()}]) ::
          Session.t()
  def send_keys(%Session{} = session, keys) do
    Enum.reduce(keys, session, fn
      {key, opts}, s -> send_key(s, key, opts)
      key, s -> send_key(s, key)
    end)
  end

  # -- Inspection (return values, not session) ---------------------------------

  @doc """
  Get the plain text screenshot of the current session.
  """
  @spec screenshot(Session.t()) :: String.t()
  def screenshot(%Session{} = session) do
    if Code.ensure_loaded?(Raxol.Headless) do
      case Raxol.Headless.screenshot(session.id) do
        {:ok, text} -> text
        {:error, reason} -> raise "screenshot failed: #{inspect(reason)}"
      end
    else
      ""
    end
  end

  @doc """
  Get the current TEA model from the session.
  """
  @spec get_model(Session.t()) :: term()
  def get_model(%Session{} = session) do
    if Code.ensure_loaded?(Raxol.Headless) do
      case Raxol.Headless.get_model(session.id) do
        {:ok, model} -> model
        {:error, reason} -> raise "get_model failed: #{inspect(reason)}"
      end
    else
      nil
    end
  end

  @doc """
  List all MCP tools currently registered for this session.

  Returns tool definitions (name, description, inputSchema).
  """
  @spec get_tools(Session.t()) :: [map()]
  def get_tools(%Session{} = session) do
    Registry.list_tools(session.registry)
  end

  @doc """
  Find a Component by ID in the current view tree.

  Returns the structured Component summary or `nil` if not found.
  """
  @spec get_component(Session.t(), String.t()) :: map() | nil
  def get_component(%Session{} = session, component_id) do
    components = get_structured_components(session)
    find_component_by_id(components, component_id)
  end

  @doc """
  Get the structured Component tree (all Components as summaries).
  """
  @spec get_structured_components(Session.t()) :: [StructuredScreenshot.widget_summary()]
  def get_structured_components(%Session{} = session) do
    uri = "raxol://session/#{session.id}/widgets"

    case Registry.read_resource(session.registry, uri) do
      {:ok, components} when is_list(components) ->
        components

      {:ok, data} when is_map(data) ->
        StructuredScreenshot.from_view_tree(data)

      _ ->
        []
    end
  end

  # -- Internal ----------------------------------------------------------------

  defp call_tool!(%Session{} = session, tool_name, args) do
    case Registry.call_tool(session.registry, tool_name, args) do
      {:ok, _result} ->
        Process.sleep(session.settle_ms)
        session

      {:error, :tool_not_found} ->
        available = Registry.list_tools(session.registry) |> Enum.map(& &1[:name])

        raise "Tool '#{tool_name}' not found. Available tools: #{inspect(available)}"

      {:error, reason} ->
        raise "Tool '#{tool_name}' failed: #{inspect(reason)}"
    end
  end

  defp find_component_by_id(components, target_id) when is_list(components) do
    Enum.find_value(components, fn component ->
      cond do
        to_string(component[:id]) == to_string(target_id) ->
          component

        is_list(component[:children]) ->
          find_component_by_id(component[:children], target_id)

        true ->
          nil
      end
    end)
  end

  defp find_component_by_id(_, _), do: nil
end
