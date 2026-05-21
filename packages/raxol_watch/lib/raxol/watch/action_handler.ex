defmodule Raxol.Watch.ActionHandler do
  @moduledoc """
  Maps watch tap actions back to Raxol Event structs and routes them
  to a configured dispatcher.

  When a user taps a notification action on their watch, the action ID
  arrives back over your transport (webhook, push response, polling).
  Call `dispatch/2` to translate it to an Event and forward it to the
  TEA app; call `handle_action/2` if you only want the Event.
  """

  alias Raxol.Core.Events.Event

  require Logger

  @default_action_map %{
    "pause" => {:key, %{key: :char, char: " "}},
    "details" => {:key, %{key: :enter}},
    "acknowledge" => {:key, %{key: :enter}},
    "quit" => {:key, %{key: :char, char: "q"}},
    "next" => {:key, %{key: :tab}},
    "previous" => {:key, %{key: :tab, modifiers: [:shift]}},
    "dismiss" => nil
  }

  @type dispatcher ::
          pid()
          | atom()
          | {module(), atom()}
          | {module(), atom(), [term()]}
          | (Event.t() -> any())

  @doc """
  Translates a watch tap action into a Raxol Event.

  Returns `nil` for actions that don't produce events (e.g. "dismiss").

  ## Options

    * `:action_map` - custom action mapping (merged with defaults)
  """
  @spec handle_action(String.t(), keyword()) :: Event.t() | nil
  def handle_action(action_id, opts \\ []) do
    actions = merge_actions(opts)

    case Map.get(actions, action_id) do
      {:key, data} -> Event.new(:key, data)
      nil -> nil
    end
  end

  @doc """
  Translates a tap action and routes the resulting Event to a dispatcher.

  Returns `{:ok, event}` if an Event was produced and dispatched,
  `{:ok, nil}` for actions that map to `nil` (e.g. "dismiss") or unknown
  action IDs, and `{:error, reason}` if dispatch failed.

  ## Options

    * `:action_map` -- custom action mapping (merged with defaults)
    * `:to` -- dispatcher override; takes precedence over app env
      - `pid` or registered `atom` name -> `send(to, {:watch_action, event})`
      - `{module, function}` -> `apply(module, function, [event])`
      - `{module, function, extra_args}` -> `apply(module, function, [event | extra_args])`
      - 1-arity function -> `fun.(event)`

  Falls back to `Application.get_env(:raxol_watch, :action_dispatcher)`
  when `:to` is not provided. If no dispatcher is configured, returns
  `{:error, :no_dispatcher}` (the Event is still returned in the tuple
  so callers can route it manually).
  """
  @spec dispatch(String.t(), keyword()) ::
          {:ok, Event.t() | nil} | {:error, term(), Event.t() | nil}
  def dispatch(action_id, opts \\ []) do
    case handle_action(action_id, opts) do
      nil ->
        {:ok, nil}

      %Event{} = event ->
        case resolve_dispatcher(opts) do
          nil -> {:error, :no_dispatcher, event}
          dispatcher -> do_dispatch(dispatcher, event)
        end
    end
  end

  @doc "Returns the default action mapping."
  @spec default_action_map() :: map()
  def default_action_map, do: @default_action_map

  defp merge_actions(opts) do
    case Keyword.get(opts, :action_map) do
      nil -> @default_action_map
      custom when is_map(custom) -> Map.merge(@default_action_map, custom)
      _ -> @default_action_map
    end
  end

  defp resolve_dispatcher(opts) do
    case Keyword.get(opts, :to) do
      nil -> Application.get_env(:raxol_watch, :action_dispatcher)
      to -> to
    end
  end

  defp do_dispatch(pid, event) when is_pid(pid) do
    send(pid, {:watch_action, event})
    {:ok, event}
  end

  defp do_dispatch(name, event) when is_atom(name) do
    case Process.whereis(name) do
      nil ->
        {:error, {:no_process, name}, event}

      pid ->
        send(pid, {:watch_action, event})
        {:ok, event}
    end
  end

  defp do_dispatch({mod, fun}, event) when is_atom(mod) and is_atom(fun) do
    apply(mod, fun, [event])
    {:ok, event}
  rescue
    e -> {:error, {:dispatch_raised, e}, event}
  end

  defp do_dispatch({mod, fun, extra}, event)
       when is_atom(mod) and is_atom(fun) and is_list(extra) do
    apply(mod, fun, [event | extra])
    {:ok, event}
  rescue
    e -> {:error, {:dispatch_raised, e}, event}
  end

  defp do_dispatch(fun, event) when is_function(fun, 1) do
    fun.(event)
    {:ok, event}
  rescue
    e -> {:error, {:dispatch_raised, e}, event}
  end

  defp do_dispatch(other, event) do
    Logger.warning("Raxol.Watch.ActionHandler: unsupported dispatcher #{inspect(other)}")
    {:error, {:bad_dispatcher, other}, event}
  end
end
