defmodule Raxol.Agent.LSPContext do
  @moduledoc """
  LSP context enrichment for agent prompts.

  Manages a Language Server Protocol connection and extracts
  diagnostics, symbols, and hover info to build context maps
  that agents can inject into their LLM prompts.

  ## Usage

      # Start an LSP client
      {:ok, client} = LSPContext.start_link(
        command: "elixir-ls",
        args: ["--stdio"],
        root_uri: "file:///path/to/project"
      )

      # Get diagnostics for a file
      {:ok, diags} = LSPContext.diagnostics(client, "file:///path/to/project/lib/foo.ex")

      # Get symbols in a file
      {:ok, symbols} = LSPContext.symbols(client, "file:///path/to/project/lib/foo.ex")

      # Build a context string for agent prompts
      context = LSPContext.format_context(client, "file:///path/to/project/lib/foo.ex")

  ## Protocol

  Uses JSON-RPC 2.0 over stdio, the same transport as the MCP client.
  The LSP server is spawned as a Port and communicated with via
  newline-delimited JSON-RPC messages with Content-Length headers.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  @type diagnostic :: %{
          uri: String.t(),
          range: range(),
          severity: :error | :warning | :info | :hint,
          message: String.t(),
          source: String.t() | nil
        }

  @type symbol :: %{
          name: String.t(),
          kind: atom(),
          range: range(),
          children: [symbol()]
        }

  @type range :: %{
          start: %{line: non_neg_integer(), character: non_neg_integer()},
          end: %{line: non_neg_integer(), character: non_neg_integer()}
        }

  defstruct [
    :command,
    :args,
    :env,
    :root_uri,
    :port,
    :buffer,
    :pending,
    :diagnostics_cache,
    next_id: 1,
    status: :starting
  ]

  @type t :: %__MODULE__{
          command: String.t(),
          args: [String.t()],
          env: [{String.t(), String.t()}],
          root_uri: String.t(),
          port: port() | nil,
          buffer: binary(),
          pending: %{pos_integer() => {GenServer.from(), atom()}},
          diagnostics_cache: %{String.t() => [diagnostic()]},
          next_id: pos_integer(),
          status: :starting | :initializing | :ready | :closed
        }

  @call_timeout 30_000
  @content_length_header "Content-Length: "

  @severity_map %{1 => :error, 2 => :warning, 3 => :info, 4 => :hint}

  @symbol_kind_map %{
    1 => :file,
    2 => :module,
    3 => :namespace,
    4 => :package,
    5 => :class,
    6 => :method,
    7 => :property,
    8 => :field,
    9 => :constructor,
    10 => :enum,
    11 => :interface,
    12 => :function,
    13 => :variable,
    14 => :constant,
    15 => :string,
    16 => :number,
    17 => :boolean,
    18 => :array,
    19 => :object,
    20 => :key,
    21 => :null,
    22 => :enum_member,
    23 => :struct,
    24 => :event,
    25 => :operator,
    26 => :type_parameter
  }

  # -- Client API ---------------------------------------------------------------

  @doc "Start an LSP context client linked to the calling process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Get diagnostics for a file URI. Returns cached diagnostics pushed by the server."
  @spec diagnostics(GenServer.server(), String.t()) :: {:ok, [diagnostic()]} | {:error, term()}
  def diagnostics(server, uri) do
    GenServer.call(server, {:diagnostics, uri}, @call_timeout)
  end

  @doc "Get document symbols for a file URI."
  @spec symbols(GenServer.server(), String.t()) :: {:ok, [symbol()]} | {:error, term()}
  def symbols(server, uri) do
    GenServer.call(server, {:symbols, uri}, @call_timeout)
  end

  @doc "Get hover information at a position in a file."
  @spec hover(GenServer.server(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def hover(server, uri, line, character) do
    GenServer.call(server, {:hover, uri, line, character}, @call_timeout)
  end

  @doc "Get the client status."
  @spec status(GenServer.server()) :: map()
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc """
  Build a formatted context string for agent prompts.

  Combines diagnostics and symbols for the given URI into
  a structured text block suitable for LLM consumption.
  """
  @spec format_context(GenServer.server(), String.t()) :: String.t()
  def format_context(server, uri) do
    diags = with {:ok, d} <- diagnostics(server, uri), do: d, else: (_ -> [])
    syms = with {:ok, s} <- symbols(server, uri), do: s, else: (_ -> [])

    format_context_from_data(uri, diags, syms)
  end

  @doc """
  Build a context string from pre-fetched data (pure function).

  Useful when you already have diagnostics and symbols
  and don't need to query the server.
  """
  @spec format_context_from_data(String.t(), [diagnostic()], [symbol()]) :: String.t()
  def format_context_from_data(uri, diagnostics, symbols) do
    parts =
      []
      |> maybe_add_diagnostics(diagnostics)
      |> maybe_add_symbols(symbols)
      |> Enum.reverse()

    case parts do
      [] -> "No LSP context available for #{uri_to_path(uri)}"
      _ -> "LSP context for #{uri_to_path(uri)}:\n\n" <> Enum.join(parts, "\n\n")
    end
  end

  defp maybe_add_diagnostics(parts, []), do: parts

  defp maybe_add_diagnostics(parts, diagnostics) do
    diag_text =
      Enum.map_join(diagnostics, "\n", fn d ->
        severity = d.severity |> to_string() |> String.upcase()
        line = d.range.start.line + 1
        source_tag = if d.source, do: " [#{d.source}]", else: ""
        "  #{severity} L#{line}: #{d.message}#{source_tag}"
      end)

    ["Diagnostics:\n#{diag_text}" | parts]
  end

  defp maybe_add_symbols(parts, []), do: parts

  defp maybe_add_symbols(parts, symbols) do
    ["Symbols:\n#{format_symbols(symbols, 0)}" | parts]
  end

  @doc "Stop the LSP server and client."
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # -- Server Callbacks ---------------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, [])
    root_uri = Keyword.get(opts, :root_uri, "file://#{File.cwd!()}")

    state = %__MODULE__{
      command: command,
      args: args,
      env: env,
      root_uri: root_uri,
      buffer: <<>>,
      pending: %{},
      diagnostics_cache: %{}
    }

    {:ok, state, {:continue, :spawn_server}}
  end

  @impl GenServer
  def handle_continue(:spawn_server, state) do
    charlist_env =
      Enum.map(state.env, fn {k, v} ->
        {String.to_charlist(k), String.to_charlist(v)}
      end)

    port_opts =
      [:binary, :exit_status, {:packet, 0}, :use_stdio]
      |> maybe_add_opt(:env, if(charlist_env != [], do: charlist_env))

    case find_executable(state.command) do
      nil ->
        Logger.warning("[LSPContext] Command not found: #{state.command}")
        {:noreply, %{state | status: :closed}}

      exec_path ->
        port =
          Port.open(
            {:spawn_executable, exec_path},
            [{:args, state.args} | port_opts]
          )

        state = %{state | port: port, status: :initializing}
        send_initialize(state)
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:diagnostics, uri}, _from, %{status: :ready} = state) do
    diags = Map.get(state.diagnostics_cache, uri, [])
    {:reply, {:ok, diags}, state}
  end

  def handle_manager_call({:diagnostics, _uri}, _from, state) do
    {:reply, {:error, {:not_ready, state.status}}, state}
  end

  def handle_manager_call({:symbols, uri}, from, %{status: :ready} = state) do
    {state, id} = next_id(state)
    state = register_pending(state, id, from, :symbols)

    params = %{
      textDocument: %{uri: uri}
    }

    send_request(state, id, "textDocument/documentSymbol", params)
    {:noreply, state}
  end

  def handle_manager_call({:symbols, _uri}, _from, state) do
    {:reply, {:error, {:not_ready, state.status}}, state}
  end

  def handle_manager_call({:hover, uri, line, character}, from, %{status: :ready} = state) do
    {state, id} = next_id(state)
    state = register_pending(state, id, from, :hover)

    params = %{
      textDocument: %{uri: uri},
      position: %{line: line, character: character}
    }

    send_request(state, id, "textDocument/hover", params)
    {:noreply, state}
  end

  def handle_manager_call({:hover, _uri, _line, _char}, _from, state) do
    {:reply, {:error, {:not_ready, state.status}}, state}
  end

  def handle_manager_call(:status, _from, state) do
    info = %{
      status: state.status,
      root_uri: state.root_uri,
      cached_diagnostics: map_size(state.diagnostics_cache),
      pending: map_size(state.pending)
    }

    {:reply, info, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({port, {:data, data}}, %{port: port} = state) do
    handle_data(state.buffer <> data, state)
  end

  def handle_manager_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("[LSPContext] Server exited with status #{code}")

    Enum.each(state.pending, fn
      {_id, {:init, _type}} -> :ok
      {_id, {from, _type}} -> GenServer.reply(from, {:error, {:server_exited, code}})
    end)

    {:noreply, %{state | port: nil, status: :closed, pending: %{}}}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{port: port}) when is_port(port) do
    send_request_fire_and_forget(%{port: port}, "shutdown", %{})
    send_notification(%{port: port}, "exit", %{})
    Port.close(port)
    :ok
  catch
    :error, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Private: LSP Message Framing (Content-Length headers) ---------------------

  defp handle_data(buffer, state) do
    case parse_lsp_message(buffer) do
      {:ok, json, rest} ->
        state = %{state | buffer: <<>>}

        state =
          case Jason.decode(json) do
            {:ok, msg} -> handle_message(msg, state)
            {:error, _} -> state
          end

        handle_data(rest, state)

      :incomplete ->
        {:noreply, %{state | buffer: buffer}}
    end
  end

  defp parse_lsp_message(buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {header_end, 4} ->
        headers = binary_part(buffer, 0, header_end)
        body_start = header_end + 4

        case parse_content_length(headers) do
          {:ok, length} ->
            remaining = byte_size(buffer) - body_start

            if remaining >= length do
              json = binary_part(buffer, body_start, length)
              rest = binary_part(buffer, body_start + length, remaining - length)
              {:ok, json, rest}
            else
              :incomplete
            end

          :error ->
            :incomplete
        end

      :nomatch ->
        :incomplete
    end
  end

  defp parse_content_length(headers) do
    headers
    |> String.split("\r\n")
    |> Enum.find_value(:error, fn line ->
      case String.split(line, ": ", parts: 2) do
        ["Content-Length", len] ->
          case Integer.parse(String.trim(len)) do
            {n, _} -> {:ok, n}
            :error -> nil
          end

        _ ->
          nil
      end
    end)
  end

  # -- Private: Message Handling ------------------------------------------------

  defp handle_message(%{"id" => id, "result" => result}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} -> state
      {{from, type}, pending} -> handle_result(type, result, from, %{state | pending: pending})
    end
  end

  defp handle_message(%{"id" => id, "error" => error}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {{from, _type}, pending} ->
        if from != :init, do: GenServer.reply(from, {:error, error})
        %{state | pending: pending}
    end
  end

  # Server-pushed diagnostics
  defp handle_message(
         %{"method" => "textDocument/publishDiagnostics", "params" => params},
         state
       ) do
    uri = Map.get(params, "uri", "")
    raw_diags = Map.get(params, "diagnostics", [])
    parsed = Enum.map(raw_diags, &parse_diagnostic(uri, &1))
    %{state | diagnostics_cache: Map.put(state.diagnostics_cache, uri, parsed)}
  end

  # Ignore other notifications
  defp handle_message(%{"method" => _}, state), do: state
  defp handle_message(_, state), do: state

  defp handle_result(:init, _result, _from, state) do
    Logger.info("[LSPContext] Server initialized for #{state.root_uri}")
    send_notification(state, "initialized", %{})
    %{state | status: :ready}
  end

  defp handle_result(:symbols, result, from, state) when is_list(result) do
    symbols = Enum.map(result, &parse_symbol/1)
    GenServer.reply(from, {:ok, symbols})
    state
  end

  defp handle_result(:symbols, nil, from, state) do
    GenServer.reply(from, {:ok, []})
    state
  end

  defp handle_result(:hover, %{"contents" => contents}, from, state) do
    text = extract_hover_text(contents)
    GenServer.reply(from, {:ok, text})
    state
  end

  defp handle_result(:hover, nil, from, state) do
    GenServer.reply(from, {:ok, nil})
    state
  end

  defp handle_result(_type, _result, from, state) do
    if from != :init, do: GenServer.reply(from, {:ok, nil})
    state
  end

  # -- Private: Initialize -------------------------------------------------------

  defp send_initialize(state) do
    {state, id} = next_id(state)

    params = %{
      processId: System.pid() |> String.to_integer(),
      rootUri: state.root_uri,
      capabilities: %{
        textDocument: %{
          publishDiagnostics: %{relatedInformation: true},
          documentSymbol: %{
            hierarchicalDocumentSymbolSupport: true
          },
          hover: %{contentFormat: ["markdown", "plaintext"]}
        }
      },
      clientInfo: %{name: "raxol", version: "1.0.0"}
    }

    state = register_pending(state, id, :init, :init)
    send_request(state, id, "initialize", params)
    {:noreply, state}
  end

  # -- Private: Protocol -------------------------------------------------------

  defp send_request(state, id, method, params) do
    msg = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    send_lsp_message(state, msg)
  end

  defp send_request_fire_and_forget(state, method, params) do
    msg = %{"jsonrpc" => "2.0", "id" => 999_999, "method" => method, "params" => params}
    send_lsp_message(state, msg)
  end

  defp send_notification(state, method, params) do
    msg = %{"jsonrpc" => "2.0", "method" => method, "params" => params}
    send_lsp_message(state, msg)
  end

  defp send_lsp_message(%{port: port}, msg) when is_port(port) do
    case Jason.encode(msg) do
      {:ok, json} ->
        frame = "#{@content_length_header}#{byte_size(json)}\r\n\r\n#{json}"
        Port.command(port, frame)

      {:error, reason} ->
        Logger.warning("[LSPContext] Failed to encode: #{inspect(reason)}")
    end
  end

  defp send_lsp_message(_, _), do: :ok

  # -- Private: Parsing ---------------------------------------------------------

  defp parse_diagnostic(uri, raw) do
    range = parse_range(Map.get(raw, "range", %{}))
    severity_code = Map.get(raw, "severity", 1)

    %{
      uri: uri,
      range: range,
      severity: Map.get(@severity_map, severity_code, :error),
      message: Map.get(raw, "message", ""),
      source: Map.get(raw, "source")
    }
  end

  defp parse_symbol(raw) do
    # Handle both DocumentSymbol and SymbolInformation formats
    range =
      case Map.get(raw, "range") || Map.get(raw, "location") do
        %{"range" => r} -> parse_range(r)
        r when is_map(r) -> parse_range(r)
        _ -> %{start: %{line: 0, character: 0}, end: %{line: 0, character: 0}}
      end

    kind_code = Map.get(raw, "kind", 1)
    children = Map.get(raw, "children", []) |> Enum.map(&parse_symbol/1)

    %{
      name: Map.get(raw, "name", ""),
      kind: Map.get(@symbol_kind_map, kind_code, :unknown),
      range: range,
      children: children
    }
  end

  defp parse_range(%{"start" => s, "end" => e}) do
    %{
      start: %{line: Map.get(s, "line", 0), character: Map.get(s, "character", 0)},
      end: %{line: Map.get(e, "line", 0), character: Map.get(e, "character", 0)}
    }
  end

  defp parse_range(_), do: %{start: %{line: 0, character: 0}, end: %{line: 0, character: 0}}

  defp extract_hover_text(contents) when is_binary(contents), do: contents

  defp extract_hover_text(%{"value" => value}), do: value

  defp extract_hover_text(contents) when is_list(contents) do
    contents
    |> Enum.map(fn
      %{"value" => v} -> v
      s when is_binary(s) -> s
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  defp extract_hover_text(_), do: nil

  # -- Private: Formatting -------------------------------------------------------

  defp format_symbols(symbols, indent) do
    prefix = String.duplicate("  ", indent)

    symbols
    |> Enum.map(fn sym ->
      line = sym.range.start.line + 1
      kind_str = to_string(sym.kind)
      entry = "#{prefix}  #{kind_str} #{sym.name} (L#{line})"

      if sym.children != [] do
        entry <> "\n" <> format_symbols(sym.children, indent + 1)
      else
        entry
      end
    end)
    |> Enum.join("\n")
  end

  defp uri_to_path("file://" <> path), do: path
  defp uri_to_path(uri), do: uri

  # -- Private: Helpers ---------------------------------------------------------

  defp next_id(state) do
    {%{state | next_id: state.next_id + 1}, state.next_id}
  end

  defp register_pending(state, id, from, type) do
    %{state | pending: Map.put(state.pending, id, {from, type})}
  end

  defp find_executable(command) do
    case System.find_executable(command) do
      nil -> nil
      path -> String.to_charlist(path)
    end
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: [{key, value} | opts]
end
