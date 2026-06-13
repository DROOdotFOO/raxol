defmodule Raxol.Watch.Notifier do
  @moduledoc """
  Subscribes to accessibility announcements and pushes notifications
  to all registered watch devices.

  Debounces pushes to at most once per second to respect watch battery
  budgets. Respects per-device mute and priority-only preferences.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.Watch.{DeviceRegistry, Formatter}

  @compile {:no_warn_undefined, [Raxol.Core.Accessibility]}

  @debounce_ms 1000

  # Permanent delivery failures: the device token should be removed from
  # the registry so we don't keep paying for failing pushes. Transient
  # failures (rate limit, server error) leave the device registered.
  @permanent_failure_reasons MapSet.new([
                               # APNS
                               :bad_device_token,
                               :device_token_not_for_topic,
                               :unregistered,
                               :expired_token,
                               # FCM
                               :invalid_argument,
                               :sender_id_mismatch
                             ])

  defstruct [
    :push_backend,
    :subscription_ref,
    :debounce_timer,
    pending: nil
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Push a notification to all registered devices immediately."
  @spec push_to_all(map()) :: :ok
  def push_to_all(notification) do
    GenServer.cast(__MODULE__, {:push_all, notification})
  end

  @doc """
  Synchronously flushes pending work. Useful in tests to avoid `Process.sleep`.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  # -- BaseManager --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    push_backend = Keyword.get(opts, :push_backend, Raxol.Watch.Push.Noop)
    ref = make_ref()

    if Code.ensure_loaded?(Raxol.Core.Accessibility) do
      try do
        Raxol.Core.Accessibility.subscribe_to_announcements(ref)
      catch
        :exit, _ -> :ok
      end
    end

    {:ok, %__MODULE__{push_backend: push_backend, subscription_ref: ref}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:flush, _from, state) do
    {:reply, :ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:push_all, notification}, state) do
    do_push_all(notification, state)
    {:noreply, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(
        {:announcement_added, _ref, %{message: message, priority: :high}},
        state
      ) do
    notification = Formatter.format_announcement(message, :high)
    do_push_all(notification, state)
    {:noreply, %{state | pending: nil}}
  end

  def handle_manager_info(
        {:announcement_added, _ref, %{message: message, priority: priority}},
        state
      ) do
    notification = Formatter.format_announcement(message, priority)
    {:noreply, debounce_push(notification, state)}
  end

  def handle_manager_info({:announcement_added, _ref, %{message: message}}, state) do
    notification = Formatter.format_announcement(message)
    {:noreply, debounce_push(notification, state)}
  end

  def handle_manager_info(:flush_pending, %{pending: nil} = state) do
    {:noreply, state}
  end

  def handle_manager_info(:flush_pending, %{pending: notification} = state) do
    do_push_all(notification, state)
    {:noreply, %{state | pending: nil, debounce_timer: nil}}
  end

  def handle_manager_info(_, state), do: {:noreply, state}

  # -- Private --

  defp debounce_push(notification, state) do
    if state.debounce_timer do
      Process.cancel_timer(state.debounce_timer)

      :telemetry.execute(
        [:raxol_watch, :notifier, :coalesced],
        %{count: 1},
        %{priority: notification.priority}
      )
    end

    timer = Process.send_after(self(), :flush_pending, @debounce_ms)
    %{state | pending: notification, debounce_timer: timer}
  end

  defp do_push_all(notification, state) do
    devices =
      DeviceRegistry.list_devices()
      |> Enum.reject(fn {_, _, prefs} ->
        prefs[:muted] or
          (prefs[:high_priority_only] and notification.priority != :high)
      end)

    backend = state.push_backend

    devices
    |> Task.async_stream(
      fn {token, platform, _prefs} ->
        push_one(backend, token, platform, notification)
      end,
      max_concurrency: 10,
      timeout: 10_000,
      on_timeout: :kill_task
    )
    |> Enum.each(fn
      {:exit, :timeout} ->
        Logger.warning("Push task timed out")

      _ ->
        :ok
    end)
  end

  defp push_one(backend, token, platform, notification) do
    meta = %{
      token: token,
      platform: platform,
      priority: notification.priority,
      backend: backend
    }

    :telemetry.span([:raxol_watch, :push], meta, fn ->
      result = backend.push(token, notification)
      handle_push_result(result, token, platform)
      {result, Map.put(meta, :result, result)}
    end)
  end

  defp handle_push_result(:ok, _token, _platform), do: :ok

  defp handle_push_result({:error, reason}, token, platform) do
    Logger.warning("Push failed for #{platform} device #{redact(token)}: #{inspect(reason)}")

    if MapSet.member?(@permanent_failure_reasons, reason) do
      DeviceRegistry.unregister(token, :delivery_failed)
    end

    :ok
  end

  defp redact(<<head::binary-size(8), _rest::binary>>), do: head <> "..."
  defp redact(other), do: inspect(other)
end
