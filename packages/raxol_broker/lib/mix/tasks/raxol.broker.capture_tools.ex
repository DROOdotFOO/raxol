defmodule Mix.Tasks.Raxol.Broker.CaptureTools do
  @moduledoc """
  Captures Robinhood's live `tools/list` into `priv/robinhood/tools_list.json`
  (or `--out PATH`), the frozen list `Raxol.Broker.Tools.Catalog` classifies
  from.

      mix run -e 'Raxol.Broker.Login.run()'   # once, if no credential is stored
      mix raxol.broker.capture_tools
      mix raxol.broker.gen.tools

  It connects with the stored credential through the read-only
  `Raxol.Broker.MCP.Client` and writes only tool metadata (name, description,
  `inputSchema`, `annotations`) plus a provenance record. Nothing is called.
  Review the diff before committing: a write or review tool whose schema
  changed is refused until the new capture is committed.
  """

  use Mix.Task

  alias Raxol.Broker.MCP.Client

  @shortdoc "Captures Robinhood's live tool list for the catalog"
  @default_out "priv/robinhood/tools_list.json"

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [out: :string])

    if rest != [] or invalid != [],
      do: Mix.raise("usage: mix raxol.broker.capture_tools [--out PATH]")

    Mix.Task.run("app.start")
    out = Keyword.get(opts, :out, @default_out)

    case capture([], out) do
      {:ok, count} ->
        Mix.shell().info("Captured #{count} tools to #{out}; now run mix raxol.broker.gen.tools")

      {:error, reason} ->
        Mix.raise("could not capture the tool list: #{inspect(reason)}")
    end
  end

  @doc false
  # The work, with the session's options (`Raxol.Broker.MCP.Client.start_link/1`)
  # exposed for the tests.
  @spec capture(keyword(), Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def capture(client_opts, out) do
    {:ok, client} = Client.start_link(client_opts)

    try do
      with {:ok, _read} <- Client.list_tools(client),
           {:ok, tools} <- Client.live_tools(client) do
        File.mkdir_p!(Path.dirname(out))
        File.write!(out, Jason.encode_to_iodata!(document(tools, client_opts), pretty: true))
        File.write!(out, "\n", [:append])
        {:ok, length(tools)}
      end
    after
      GenServer.stop(client)
    end
  end

  defp document(tools, client_opts) do
    %{
      "provenance" => %{
        "source" =>
          Keyword.get(client_opts, :url, "https://agent.robinhood.com/mcp/trading") <>
            " tools/list",
        "captured" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "note" => "Captured by mix raxol.broker.capture_tools; unsanitized tool metadata."
      },
      "tools" => tools |> Enum.map(&wire/1) |> Enum.sort_by(& &1["name"])
    }
  end

  defp wire(tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "inputSchema" => tool.input_schema
    }
    |> then(fn wire ->
      if tool.annotations == %{}, do: wire, else: Map.put(wire, "annotations", tool.annotations)
    end)
  end
end
