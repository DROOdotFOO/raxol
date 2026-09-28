defmodule Raxol.Core.Runtime.Plugins.Plugin do
  @moduledoc """
  Defines the behaviour for Raxol plugins.

  Plugins must implement this behaviour to be loaded and managed by the plugin manager.
  """

  @type config :: map()
  @type state :: map()
  # Events are generic terms
  @type event :: term()
  @type command :: atom() | tuple()

  @doc """
  Called when the plugin is first initialized.

  Should return `{:ok, initial_state}` or `{:error, reason}`.
  The plugin's stable runtime process owns `initial_state` for the loaded
  lifetime.
  """
  @callback init(config :: config()) :: {:ok, state()} | {:error, any()}

  @doc """
  Called when the plugin is terminated (e.g., during shutdown or unload).

  Allows the plugin to perform cleanup. The return value is ignored.
  """
  @callback terminate(reason :: any(), state :: state()) :: any()

  @doc """
  Called when the plugin is enabled after being disabled.

  Should return `{:ok, new_state}` or `{:error, reason}`.
  """
  @callback enable(state :: state()) :: {:ok, state()} | {:error, any()}

  @doc """
  Called when the plugin is disabled.

  Should return `{:ok, new_state}` or `{:error, reason}`.
  """
  @callback disable(state :: state()) :: {:ok, state()} | {:error, any()}

  @doc """
  Optional callback to filter or react to system events before they reach the application.

  Return `{:ok, event}` to pass the event through (potentially modified).
  Return `:halt` to stop the event from propagating further.
  Return any other value to indicate an error.
  """
  @callback filter_event(event :: event(), state :: state()) ::
              {:ok, event()} | :halt | any()

  @doc """
  Optional callback to handle commands delegated by the plugin manager.

  Should return `{:ok, new_state, result}` or `{:error, reason, new_state}`.
  The `result` can be sent back to the original command requester if needed.
  """
  @callback handle_command(
              command :: command(),
              args :: list(),
              state :: state()
            ) ::
              {:ok, state(), any()} | {:error, any(), state()}

  @doc """
  Optional callback to declare commands provided by the plugin.

  This callback allows plugins to register their commands with the command registry.
  Each command is specified as a tuple containing:
  - The command name as an atom
  - The function to handle the command
  - The arity of the handler function

  ## Returns

    * List of command specifications in the format `[{name_atom, function_atom, arity_integer}]`

  ## Examples

      def get_commands do
        [
          {:do_something, :handle_do_something_command, 2},
          {:process_data, :handle_process_data_command, 1}
        ]
      end

  ## Notes

    * The command name will be converted to a string when registered
    * The plugin module itself will be used as the namespace
    * Commands will be registered in the CommandRegistry via CommandHelper
  """
  @callback get_commands() :: [{atom(), atom(), non_neg_integer()}]
end
