defmodule Raxol.Core.Runtime.Subscription do
  @moduledoc """
  Provides a way to subscribe to recurring updates and external events.

  Subscriptions allow applications to receive messages over time without
  explicitly requesting them. This is useful for:
  * Timer-based updates (animation, polling)
  * Events dispatched through `Raxol.Core.Events.EventManager`
  * External data streams (file changes, network events)

  ## Types of Subscriptions

  * `:interval` - Regular time-based updates
  * `:events` - Events dispatched through `Raxol.Core.Events.EventManager`
  * `:file_watch` - File system changes
  * `:custom` - Custom event sources

  ## Examples

      # Update every second
      Subscription.interval(1000, :tick)

      # Listen for specific EventManager events
      Subscription.events([:theme_changed, :accessibility_enabled])

      # Watch a file for changes
      Subscription.file_watch("config.json", [:modify, :delete])

      # Custom subscription
      Subscription.custom(MyEventSource, :start_listening)
  """

  @type t :: %__MODULE__{
          type: :interval | :events | :file_watch | :custom,
          data: term()
        }

  defstruct [:type, :data]

  @doc """
  Creates a new subscription. This is the low-level constructor, prefer using
  the specific subscription constructors unless you need custom behavior.
  """
  def new(type, data) do
    %__MODULE__{type: type, data: data}
  end

  @doc """
  Creates a subscription that will send a message at regular intervals.

  ## Options
    * `:start_immediately` - Send first message immediately (default: false)
    * `:jitter` - Add random jitter to interval (default: 0)
  """
  def interval(interval_ms, msg, opts \\ [])

  def interval(interval_ms, msg, opts)
      when is_integer(interval_ms) and interval_ms > 0 do
    data = %{
      interval: interval_ms,
      message: msg,
      start_immediately: Keyword.get(opts, :start_immediately, false),
      jitter: Keyword.get(opts, :jitter, 0)
    }

    new(:interval, data)
  end

  def interval(_interval_ms, _msg, _opts) do
    {:error, :invalid_interval}
  end

  @doc """
  Creates a subscription for events dispatched through
  `Raxol.Core.Events.EventManager` (`EventManager.dispatch/1,2` or
  `EventManager.notify/3`).

  Each matching event reaches the app's `update/2` as
  `{:event, event_type, event_data}`.

  Only EventManager-dispatched events arrive this way. Terminal input (key
  presses, mouse, resize, focus) is not routed through EventManager: it reaches
  `update/2` as a `Raxol.Core.Events.Event` struct without any subscription.
  Events the framework dispatches include `:theme_changed`,
  `:high_contrast_changed`, `:accessibility_enabled`,
  `:accessibility_disabled`, `:accessibility_preference_changed`,
  `:screen_reader_announcement`, `:activate` and `:dismiss`.
  """
  def events(event_types) when is_list(event_types) do
    new(:events, event_types)
  end

  def events(_event_types) do
    {:error, :invalid_events}
  end

  @doc """
  Creates a subscription that watches for file system changes.

  ## Event Types
    * `:modify` - File content changes
    * `:delete` - File deletion
    * `:create` - File creation
    * `:rename` - File rename
    * `:attrib` - Attribute changes

  Returns `{:error, :invalid_file_watch_args}` if event_types is not a list.
  """
  def file_watch(path, event_types \\ [:modify])

  def file_watch(path, event_types) when is_list(event_types) do
    data = %{
      path: path,
      events: event_types
    }

    new(:file_watch, data)
  end

  def file_watch(_path, _event_types), do: {:error, :invalid_file_watch_args}

  @doc """
  Creates a custom subscription using a provided event source.
  The event source should implement the `Raxol.Core.Runtime.EventSource`
  behaviour.
  """
  def custom(source_module, _init_args) when not is_atom(source_module) do
    {:error, :invalid_module}
  end

  def custom(_source_module, init_args) when not is_map(init_args) do
    {:error, :invalid_args}
  end

  def custom(source_module, init_args) do
    data = %{module: source_module, args: init_args}
    new(:custom, data)
  end

  @doc """
  Starts a subscription within the given context. This is used by the runtime
  system and should not be called directly by applications.

  Returns `{:ok, subscription_id}` or `{:error, reason}`.
  """
  def start(%__MODULE__{} = subscription, context) do
    # Validate context has required pid
    case Map.has_key?(context, :pid) do
      false ->
        {:error, :invalid_context}

      true ->
        case subscription do
          %{type: :interval, data: data} ->
            start_interval(data, context)

          %{type: :events, data: event_types} ->
            start_event_subscription(event_types, context)

          %{type: :file_watch, data: data} ->
            start_file_watch(data, context)

          %{type: :custom, data: data} ->
            start_custom_subscription(data, context)

          %{type: _invalid_type, data: _data} ->
            {:error, :invalid_subscription_type}
        end
    end
  end

  @doc """
  Stops a subscription. This is used by the runtime system and should not
  be called directly by applications.
  """
  def stop(subscription_id) do
    stop_subscription(subscription_id)
  end

  defp stop_subscription({:interval, timer_ref}), do: stop_interval(timer_ref)
  defp stop_subscription({:events, actual_id}), do: stop_events(actual_id)

  defp stop_subscription({:file_watch, watcher_pid}),
    do: stop_file_watch(watcher_pid)

  defp stop_subscription({:custom, source_pid}), do: stop_custom(source_pid)
  defp stop_subscription(_), do: {:error, :invalid_subscription}

  defp stop_interval(timer_ref) do
    case :timer.cancel(timer_ref) do
      {:ok, :cancel} -> :ok
      {:error, :badarg} -> {:error, :subscription_not_found}
      {:error, reason} -> {:error, {:timer_cancel_error, reason}}
    end
  end

  defp stop_events(actual_id)
       when is_integer(actual_id) or is_reference(actual_id) do
    Raxol.Core.Events.EventManager.unsubscribe(actual_id)
  end

  defp stop_events(_actual_id) do
    {:error, :invalid_subscription_id}
  end

  defp stop_file_watch(watcher_pid) do
    case Process.alive?(watcher_pid) do
      true ->
        Process.exit(watcher_pid, :normal)
        :ok

      false ->
        {:error, :subscription_not_found}
    end
  end

  defp stop_custom(source_pid) do
    case Process.alive?(source_pid) do
      true ->
        Process.exit(source_pid, :normal)
        :ok

      false ->
        {:error, :subscription_not_found}
    end
  end

  # Private helpers for starting different types of subscriptions

  defp start_interval(data, context) do
    %{
      interval: interval,
      message: msg,
      start_immediately: immediate,
      jitter: jitter
    } = data

    case immediate do
      true -> send(context.pid, {:subscription, msg})
      false -> :ok
    end

    # Calculate jitter safely, ensuring we don't call :rand.uniform with 0
    jitter_ms =
      case jitter > 0 do
        true -> :rand.uniform(jitter)
        false -> 0
      end

    # Add error handling for timer creation
    case :timer.send_interval(
           interval + jitter_ms,
           context.pid,
           {:subscription, msg}
         ) do
      {:ok, timer_ref} ->
        {:ok, {:interval, timer_ref}}

      {:error, reason} ->
        {:error, {:timer_creation_error, reason}}
    end
  end

  defp start_event_subscription(event_types, _context) do
    case Raxol.Core.Events.EventManager.subscribe(event_types, []) do
      {:ok, subscription_id} ->
        {:ok, {:events, subscription_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_file_watch(data, context) do
    %{path: path, events: events} = data

    # Check if file exists before starting watch
    case File.exists?(path) do
      false ->
        {:error, :invalid_file_path}

      true ->
        {:ok, pid} =
          Task.start(fn ->
            watch_file(path, events, context.pid)
          end)

        # Unlink so file watch crashes don't kill the dispatcher.
        Process.unlink(pid)
        {:ok, {:file_watch, pid}}
    end
  end

  defp start_custom_subscription(data, context) do
    %{module: module, args: args} = data

    case module.start_link(args, context) do
      {:ok, pid} ->
        Process.unlink(pid)
        {:ok, {:custom, pid}}

      error ->
        error
    end
  end

  # File watching helper
  defp watch_file(path, events, target_pid) do
    case FileSystem.start_link(dirs: [path]) do
      {:ok, watcher_pid} ->
        :ok = FileSystem.subscribe(watcher_pid)

        receive do
          {_watcher_pid, {:file_event, path, file_events}} ->
            case Enum.any?(file_events, &(&1 in events)) do
              true ->
                send(
                  target_pid,
                  {:subscription, {:file_change, path, file_events}}
                )

              false ->
                :ok
            end
        after
          5000 ->
            # Timeout after 5 seconds if no file events are received
            send(target_pid, {:subscription, {:file_watch_timeout, path}})
        end

        # Continue watching
        watch_file(path, events, target_pid)

      {:error, reason} ->
        send(
          target_pid,
          {:subscription, {:file_watch_error, {:start_error, reason}}}
        )
    end
  end
end
