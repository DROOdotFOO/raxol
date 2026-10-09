defmodule Raxol.Broker.Tools do
  @moduledoc """
  The read tools as typed functions. `Raxol.Broker.Tools.<Family>` modules
  are generated from the capture by `mix raxol.broker.gen.tools` (see
  `Raxol.Broker.Tools.Generator`); each function validates its arguments
  against the captured `inputSchema` and calls the read-only session.

  Only `:read` tools are generated. Review and order tools are reached only
  through `Raxol.Broker.Executor`, never through a function here.
  """

  alias Raxol.Broker.MCP.Client
  alias Raxol.Broker.Tools.{Catalog, Schema}

  @doc """
  Validate `args` against `tool`'s captured schema, then call it on the
  read-only session `client`.
  """
  @spec call(GenServer.server(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(client, tool, args) when is_binary(tool) and is_map(args) do
    with :read <- Catalog.classify(tool),
         :ok <- validate(tool, args) do
      Client.call(client, tool, args)
    else
      {:error, _} = error -> error
      class -> {:error, {:tool_refused, tool, class}}
    end
  end

  defp validate(tool, args) do
    case Schema.validate(Catalog.schema(tool), args) do
      :ok -> :ok
      {:error, errors} -> {:error, {:invalid_args, tool, errors}}
    end
  end
end
