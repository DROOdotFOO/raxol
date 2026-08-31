defmodule Raxol.Agent.Lsp.Config do
  @moduledoc """
  Which language server serves which file, from built-in defaults plus an
  optional per-repo `.raxol/lsp.json`.

  ## File shape

      {
        "servers": {
          "elixir": {
            "command": "elixir-ls",
            "args": [],
            "extensions": [".ex", ".exs"],
            "language_id": "elixir"
          }
        }
      }

  A server named the same as a built-in replaces it outright rather than
  merging field by field, so a repo that overrides `command` does not
  silently inherit arguments meant for a different binary.

  A malformed or unreadable file yields the built-in defaults rather than an
  error: a bad `.raxol/lsp.json` degrades the agent to no LSP, it does not
  stop it booting. `mix raxol.inspect` reports what resolved.

  ## Availability

  A server is only offered if its command is on `PATH`. Nothing here starts
  a process; `available?/1` is what keeps the tool from advertising an
  operation that would fail on every call.
  """

  @type server :: %{
          name: String.t(),
          command: String.t(),
          args: [String.t()],
          extensions: [String.t()],
          language_id: String.t()
        }

  @defaults [
    %{
      name: "elixir",
      command: "elixir-ls",
      args: [],
      extensions: [".ex", ".exs", ".heex"],
      language_id: "elixir"
    },
    %{
      name: "rust",
      command: "rust-analyzer",
      args: [],
      extensions: [".rs"],
      language_id: "rust"
    },
    %{
      name: "typescript",
      command: "typescript-language-server",
      args: ["--stdio"],
      extensions: [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"],
      language_id: "typescript"
    },
    %{
      name: "python",
      command: "pyright-langserver",
      args: ["--stdio"],
      extensions: [".py", ".pyi"],
      language_id: "python"
    },
    %{
      name: "go",
      command: "gopls",
      args: [],
      extensions: [".go"],
      language_id: "go"
    }
  ]

  @doc "The built-in server table, before any repo override."
  @spec defaults() :: [server()]
  def defaults, do: @defaults

  @doc """
  Resolve the server table for `dir`: built-in defaults with any
  `.raxol/lsp.json` entries replacing same-named ones and adding new ones.

  Never raises.
  """
  @spec load(String.t()) :: [server()]
  def load(dir) do
    overrides =
      dir
      |> Path.join(".raxol/lsp.json")
      |> read_overrides()

    by_name =
      Enum.reduce(overrides, Map.new(@defaults, &{&1.name, &1}), fn server, acc ->
        Map.put(acc, server.name, server)
      end)

    by_name |> Map.values() |> Enum.sort_by(& &1.name)
  end

  @doc """
  The server that handles `path`, matched on file extension.

  Returns `{:error, :no_server}` when no configured server claims the
  extension, and `{:error, {:not_installed, command}}` when one does but its
  command is not on `PATH` — the two are different problems with different
  fixes, so they are different answers.
  """
  @spec for_path([server()], String.t()) ::
          {:ok, server()} | {:error, :no_server | {:not_installed, String.t()}}
  def for_path(servers, path) do
    extension = path |> Path.extname() |> String.downcase()

    case Enum.find(servers, &(extension in &1.extensions)) do
      nil ->
        {:error, :no_server}

      server ->
        if available?(server), do: {:ok, server}, else: {:error, {:not_installed, server.command}}
    end
  end

  @doc "Whether the server's command is on `PATH`."
  @spec available?(server()) :: boolean()
  def available?(%{command: command}), do: System.find_executable(command) != nil

  # -- parsing ----------------------------------------------------------------

  defp read_overrides(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, %{"servers" => servers}} when is_map(servers) <- Jason.decode(binary) do
      servers
      |> Enum.flat_map(&parse_server/1)
      |> Enum.sort_by(& &1.name)
    else
      _ -> []
    end
  end

  # A server with no command cannot be started, and one with no extensions
  # can never be selected; both are dropped rather than carried as an entry
  # that does nothing.
  defp parse_server({name, %{"command" => command} = spec})
       when is_binary(name) and name != "" and is_binary(command) and command != "" do
    case strings(Map.get(spec, "extensions")) || default_extensions(name) do
      [] ->
        []

      extensions ->
        [
          %{
            name: name,
            command: command,
            args: strings(Map.get(spec, "args")) || [],
            extensions: Enum.map(extensions, &String.downcase/1),
            language_id: language_id(spec, name)
          }
        ]
    end
  end

  defp parse_server(_entry), do: []

  # Overriding a built-in by name inherits nothing but its extensions, so
  # `{"elixir": {"command": "lexical"}}` still serves `.ex` without the repo
  # having to restate the list.
  defp default_extensions(name) do
    case Enum.find(@defaults, &(&1.name == name)) do
      nil -> []
      server -> server.extensions
    end
  end

  defp language_id(spec, name) do
    case Map.get(spec, "language_id") do
      id when is_binary(id) and id != "" -> id
      _ -> default_language_id(name)
    end
  end

  defp default_language_id(name) do
    case Enum.find(@defaults, &(&1.name == name)) do
      nil -> name
      server -> server.language_id
    end
  end

  defp strings(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: list
  end

  defp strings(_other), do: nil
end
