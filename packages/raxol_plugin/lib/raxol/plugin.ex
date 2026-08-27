defmodule Raxol.Plugin do
  @moduledoc """
  Convenience macro for building Raxol plugins.

  Sets `@behaviour Raxol.Core.Runtime.Plugins.Plugin` and provides
  overridable defaults for all optional callbacks. Only `init/1` must
  be implemented by the consumer.

  ## Usage

      defmodule MyPlugin do
        use Raxol.Plugin

        @impl true
        def init(config) do
          {:ok, %{config: config}}
        end
      end

  All other callbacks (`terminate/2`, `enable/1`, `disable/1`,
  `filter_event/2`, `handle_command/3`, `get_commands/0`) have safe
  defaults that can be overridden with `@impl true`.
  """

  @compile {:no_warn_undefined, Raxol.Core.Runtime.Plugins.Plugin}

  defmacro __using__(_opts) do
    quote do
      @compile {:no_warn_undefined, Raxol.Core.Runtime.Plugins.Plugin}
      @behaviour Raxol.Core.Runtime.Plugins.Plugin

      @doc false
      @impl Raxol.Core.Runtime.Plugins.Plugin
      def terminate(_reason, _state), do: :ok

      @doc false
      @impl Raxol.Core.Runtime.Plugins.Plugin
      def enable(state), do: {:ok, state}

      @doc false
      @impl Raxol.Core.Runtime.Plugins.Plugin
      def disable(state), do: {:ok, state}

      @doc false
      @impl Raxol.Core.Runtime.Plugins.Plugin
      def filter_event(event, _state), do: {:ok, event}

      @doc false
      @impl Raxol.Core.Runtime.Plugins.Plugin
      def handle_command(_command, _args, state), do: {:ok, state, :noop}

      @doc false
      @impl Raxol.Core.Runtime.Plugins.Plugin
      def get_commands, do: []

      defoverridable terminate: 2,
                     enable: 1,
                     disable: 1,
                     filter_event: 2,
                     handle_command: 3,
                     get_commands: 0
    end
  end
end
