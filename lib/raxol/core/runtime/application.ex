defmodule Raxol.Core.Runtime.Application do
  @moduledoc """
  Defines the behaviour for Raxol applications following The Elm Architecture (TEA).

  This module provides the core structure for building terminal applications using
  a pure functional approach with unidirectional data flow. The architecture is
  composed of three main parts:

  1. **Model** - The complete state of your application
  2. **Update** - A way to update your state
  3. **View** - A way to view your state as UI elements

  ## Example

      defmodule MyApp do
        use Raxol.Core.Runtime.Application

        def init(_context) do
          %{count: 0}
        end

        def update(msg, model) do
          case msg do
            :increment ->
              {%{model | count: model.count + 1}, []}
            :decrement ->
              {%{model | count: model.count - 1}, []}
            _ ->
              {model, []}
          end
        end

        def view(model) do
          view do
            panel title: "Counter" do
              row do
                button(label: "-", on_click: :decrement)
                text(content: "Count: \#{model.count}")
                button(label: "+", on_click: :increment)
              end
            end
          end
        end

        def subscribe(_model) do
          # Optional subscriptions to time-based or external events
          []
        end
      end

  ## Lifecycle

  1. The application starts with `init/1`, which sets up the initial state
  2. Events or messages trigger `update/2`, which computes the new state
  3. State changes cause `view/1` to re-render the UI
  4. `subscribe/1` can set up recurring updates or external event subscriptions

  ## Commands and Effects

  The update function returns a tuple of `{new_state, commands}`, where commands
  are used to handle side effects like:
  - API calls
  - File operations
  - Timer operations
  - Inter-process communication

  Commands are executed by the runtime system, keeping the update function pure.

  ## Subscriptions

  Subscriptions allow your application to receive messages over time, such as:
  - Timer-based updates
  - System events
  - External data streams

  Define subscriptions in the `subscribe/1` callback, which is called after
  initialization and after each state update.
  """

  @type context :: map()
  @type state :: term()
  @type message :: term()
  @type command :: term()
  @type subscription :: term()
  @type element :: Raxol.Core.Renderer.Element.t()

  @doc """
  Initializes the application state.

  Called once when the application starts. The context map contains runtime
  information such as terminal dimensions, environment variables, and startup
  arguments.

  Returns either:
  - Initial state: `state()`
  - State and commands: `{state(), [command()]}`
  """
  @callback init(context()) :: state() | {state(), [command()]}

  @doc """
  Updates the application state in response to messages.

  Called whenever a message is received, either from events, commands, or
  subscriptions. Should be a pure function that computes the new state
  based on the current state and message.

  Returns a tuple of the new state and any commands to be executed:
  `{state(), [command()]}`
  """
  @callback update(message(), state()) :: {state(), [command()]}

  @doc """
  Renders the current state as UI elements.

  Called after every state update to generate the new view. Should be a
  pure function that converts the state into UI elements.

  Returns an element tree that will be rendered to the terminal.
  """
  @callback view(state()) :: element()

  @doc """
  Sets up subscriptions based on the current state.

  Called after initialization and after each state update. Use this to
  set up recurring updates or subscribe to external events.

  Returns a list of subscription specifications.
  """
  @callback subscribe(state()) :: [subscription()]

  @optional_callbacks [
    subscribe: 1,
    subscriptions: 1,
    terminate: 2,
    handle_event: 1,
    handle_tick: 1,
    handle_message: 2
  ]

  # Placeholder for model type, user application should define this
  # Or we rely on Dialyzer inference
  # @type model :: %{required(integer) => any()} | map() # Example constraint
  @type model :: any()

  defmacro __using__(_opts) do
    quote do
      @behaviour Raxol.Core.Runtime.Application

      import Raxol.Core.Renderer.View, except: [view: 1]

      import Raxol.Core.Focus,
        only: [setup_focus: 1, focused?: 1, current_focus: 0]

      import Raxol.Core.Events.Event, only: [key_match: 1, key_match: 2]
      alias Raxol.Core.Events.Event
      alias Raxol.Core.Runtime.Directive
      alias Raxol.Core.Runtime.Subscription

      # Default implementations
      def init(_), do: %{}
      def update(_, state), do: {state, []}
      def view(_), do: view(do: text(content: "Default view"))
      def subscribe(_), do: []

      # Allow overriding
      defoverridable init: 1, update: 2, view: 1, subscribe: 1

      def subscribe_to_events(events) when is_list(events) do
        Subscription.events(events)
      end

      def subscribe_interval(interval, msg) do
        case {is_integer(interval), interval > 0} do
          {true, true} -> Subscription.interval(interval, msg)
          _ -> {:error, :invalid_argument}
        end
      end
    end
  end

  @doc """
  Delegates initialization to the provided application module.

  Attempts to call the `init/1` callback on the given module, handles the result,
  and returns a standardized tuple of `{model, commands}` or an error.

  ## Parameters
    - app_module: The module that implements the Application behavior
    - context: The initialization context containing runtime information

  ## Returns
    - `{model, commands}` tuple when successful
    - `{:error, reason}` tuple when initialization fails
  """
  def delegate_init(app_module, context) when is_atom(app_module) do
    alias Raxol.Core.Runtime.Log

    Log.info("[#{__MODULE__}] Delegating init to #{inspect(app_module)}...")

    with true <- function_exported?(app_module, :init, 1),
         {:ok, result} <- safely_call_init(app_module, context),
         {:ok, {model, commands}} <- normalize_init_result(app_module, result) do
      {model, commands}
    else
      false ->
        Log.warning_with_context(
          "[#{__MODULE__}] Module #{inspect(app_module)} does not export init/1. Using default empty state.",
          %{
            module: __MODULE__,
            app_module: app_module,
            warning: :no_init_exported
          }
        )

        {%{}, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private helper functions for delegate_init

  defp safely_call_init(app_module, context) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           result = app_module.init(context)

           Raxol.Core.Runtime.Log.debug(
             "[#{__MODULE__}] #{inspect(app_module)}.init/1 returned: #{inspect(result)}"
           )

           result
         end) do
      {:ok, result} ->
        {:ok, result}

      {:error, error} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "[#{__MODULE__}] Error executing #{inspect(app_module)}.init/1",
          error,
          nil,
          %{module: __MODULE__, app_module: app_module}
        )

        {:error, {:init_failed, error}}
    end
  end

  defp normalize_init_result(app_module, result) do
    case result do
      {model, commands} when is_map(model) and is_list(commands) ->
        {:ok, {model, commands}}

      model when is_map(model) ->
        # If only model is returned, default to no commands
        {:ok, {model, []}}

      invalid_return ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "[#{__MODULE__}] #{inspect(app_module)}.init/1 returned invalid value: #{inspect(invalid_return)}. Expected map() or {map(), list()}.",
          nil,
          nil,
          %{invalid_return: invalid_return, app_module: app_module}
        )

        # Return empty model with no commands as fallback
        {:ok, {%{}, []}}
    end
  end

  def delegate_update(app_module, message, current_model)
      when is_atom(app_module) do
    with true <- function_exported?(app_module, :update, 2),
         {:ok, result} <-
           safely_call_update(app_module, message, current_model),
         {:ok, {new_model, commands}} <-
           normalize_update_result(app_module, result, message, current_model) do
      {new_model, commands}
    else
      false ->
        log_missing_update_callback(app_module, message, current_model)
        {:error, :update_callback_not_implemented}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safely_call_update(app_module, message, current_model) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           app_module.update(message, current_model)
         end) do
      {:ok, result} ->
        {:ok, result}

      {:error, error} ->
        log_update_error(app_module, error, message, current_model)
        {:error, {:update_failed, error}}
    end
  end

  defp normalize_update_result(app_module, result, message, current_model) do
    case result do
      {new_model, commands} when is_map(new_model) and is_list(commands) ->
        {:ok, {new_model, commands}}

      {new_model, effect} when is_map(new_model) and is_struct(effect) ->
        normalize_single_effect(
          app_module,
          new_model,
          effect,
          message,
          current_model
        )

      invalid_return ->
        log_invalid_update_result(
          app_module,
          invalid_return,
          message,
          current_model
        )

        {:error, :invalid_update_result}
    end
  end

  defp normalize_single_effect(
         app_module,
         new_model,
         effect,
         message,
         current_model
       ) do
    if known_effect?(effect) do
      {:ok, {new_model, [effect]}}
    else
      log_invalid_update_result(
        app_module,
        {new_model, effect},
        message,
        current_model
      )

      {:error, :invalid_update_result}
    end
  end

  defp known_effect?(effect) do
    is_struct(effect) and
      Raxol.Core.Runtime.Directive.Executor.impl_for(effect) != nil
  end

  defp log_missing_update_callback(app_module, message, current_model) do
    Raxol.Core.Runtime.Log.error_with_stacktrace(
      "[#{__MODULE__}] Application module #{inspect(app_module)} does not implement update/2 callback.",
      nil,
      nil,
      %{
        module: __MODULE__,
        app_module: app_module,
        message: message,
        current_model: current_model,
        error: :update_callback_not_implemented
      }
    )
  end

  defp log_update_error(app_module, error, message, current_model) do
    Raxol.Core.Runtime.Log.error_with_stacktrace(
      "[#{__MODULE__}] Error executing #{inspect(app_module)}.update/2",
      error,
      nil,
      %{
        module: __MODULE__,
        app_module: app_module,
        message: message,
        current_model: current_model,
        error: :update_failed
      }
    )
  end

  defp log_invalid_update_result(
         app_module,
         invalid_return,
         message,
         current_model
       ) do
    Raxol.Core.Runtime.Log.error_with_stacktrace(
      "[#{__MODULE__}] #{inspect(app_module)}.update/2 returned invalid value: #{inspect(invalid_return)}. Expected {map(), list()}. Falling back to previous model with no commands.",
      nil,
      nil,
      %{
        module: __MODULE__,
        app_module: app_module,
        message: message,
        current_model: current_model,
        invalid_return: invalid_return
      }
    )
  end

  @doc """
  Gets environment configuration for the application.
  """
  def get_env(app, key, default \\ nil) do
    Raxol.Core.Runtime.Log.debug(
      "[#{__MODULE__}] get_env called for: #{app}.#{key}"
    )

    Application.get_env(app, key, default)
  end

  @callback init(context :: context()) ::
              {model(), [command()]}
              | {model(), command()}
              | model()
              | {:error, term()}

  @callback update(message :: message(), model :: model()) ::
              {model(), [command()]} | {model(), command()} | model()

  @callback view(model :: model()) :: term() | nil

  @callback subscriptions(model :: model()) ::
              [Raxol.Core.Runtime.Subscription.t()]
              | Raxol.Core.Runtime.Subscription.t()
              | []

  # Optional callbacks
  @callback handle_event(Raxol.Core.Events.Event.t()) :: message() | :halt | nil
  @callback handle_tick(model :: model()) :: {model(), [command()]}
  @callback handle_message(message :: any(), model :: model()) ::
              {model(), [command()]}

  @callback terminate(reason :: any(), model :: model()) :: any()

  # --- Placeholder Implementations for Helper Functions ---
  # These are not part of the behaviour but are called by the runtime.

  @doc """
  Initializes the application state.

  Called once when the application starts. The context map contains runtime
  information such as terminal dimensions, environment variables, and startup
  arguments.

  A simpler version of delegate_init that provides fallbacks for different return types
  from application modules.

  ## Returns
    - `{model, commands}` tuple when successful
    - `{:error, reason}` tuple when initialization fails
  """
  def init(app_module, context) do
    case delegate_init(app_module, context) do
      {:error, _} = error -> error
      {model, commands} -> {model, commands}
    end
  end

  @doc """
  Handles incoming events or messages and updates the application state.

  Returns the updated model and optional commands to execute.
  """
  def update(app_module, message, model) do
    case function_exported?(app_module, :update, 2) do
      true ->
        case app_module.update(message, model) do
          {updated_model, commands} when is_list(commands) ->
            {updated_model, commands}

          {updated_model, command} ->
            {updated_model, [command]}

          updated_model when is_map(updated_model) ->
            {updated_model, []}

          # Allow returning only commands? Maybe not standard TEA.
          _ ->
            # Assume no change if return value is unexpected
            {model, []}
        end

      false ->
        # Default implementation if update/2 is not defined
        {model, []}
    end
  end

  # Add other delegating functions as needed (view, subscriptions, handle_event)
end
