defmodule Raxol.MCP.ResourceProvider do
  @moduledoc """
  Behaviour for TEA apps that expose model state as MCP resources.

  Apps implement `mcp_resources/0` to declare named projections of their
  model. Each projection becomes a browsable MCP resource at
  `raxol://session/{id}/model/{key}`.

  ## Example

      defmodule MyApp do
        use Raxol.Core.Runtime.Application
        @behaviour Raxol.MCP.ResourceProvider

        @impl Raxol.MCP.ResourceProvider
        def mcp_resources do
          [
            {"counters", &Map.get(&1, :counters, %{})},
            {"status", fn model -> %{state: model.state, uptime: model.uptime} end}
          ]
        end

        # ... init/1, update/2, view/1
      end

  The `ToolSynchronizer` checks for this callback at init and registers
  resources accordingly, updating them on each model change.
  """

  @typedoc "A named projection: `{key, fn model -> term end}`"
  @type projection :: {String.t(), (map() -> term())}

  @doc """
  Return a list of named model projections.

  Each tuple is `{key, projection_fn}` where `key` becomes the resource
  path segment and `projection_fn` extracts data from the TEA model.
  """
  @callback mcp_resources() :: [projection()]

  @optional_callbacks mcp_resources: 0
end
