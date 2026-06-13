defmodule RaxolPlaygroundWeb.Playground.DemoLifecycle do
  @moduledoc """
  Shared demo lifecycle management for the playground and demo LiveViews.

  Provides both the start/stop primitives that own a Lifecycle process and
  the handle_info bodies that PlaygroundLive and DemoLive both wire up the
  same way: `render_update/2`, `demo_timeout/1`, `lifecycle_down/2`, plus
  the `maybe_push_reset/1` and `maybe_push_error/1` hook-bridge helpers.

  LandingLive uses `start_demo/3` and `stop_demo/1` but implements its own
  handlers because its policy is auto-restart on timeout rather than
  "session ended, click retry."
  """

  require Logger

  alias Raxol.Core.Runtime.Lifecycle
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  @doc "Starts a demo lifecycle for the given component."
  def start_demo(socket, component, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms)
    topic_prefix = Keyword.get(opts, :topic_prefix, "demo")

    if component && Phoenix.LiveView.connected?(socket) do
      topic =
        "#{topic_prefix}:#{inspect(self())}:#{System.unique_integer([:positive])}"

      try do
        Phoenix.PubSub.subscribe(Raxol.PubSub, topic)

        case Lifecycle.start_link(component.module,
               environment: :liveview,
               liveview_topic: topic,
               width: 80,
               height: 24
             ) do
          {:ok, pid} ->
            # Unlink so Lifecycle crashes don't kill the LiveView.
            # The monitor below is sufficient for detecting death.
            Process.unlink(pid)
            Process.monitor(pid)

            timer =
              if timeout_ms,
                do: Process.send_after(self(), :demo_timeout, timeout_ms)

            # Resolve the dispatcher pid once so per-keystroke dispatch can
            # skip the GenServer.call(lifecycle, :get_full_state) roundtrip.
            dispatcher_pid = fetch_dispatcher_pid(pid)

            assign(socket,
              lifecycle_pid: pid,
              dispatcher_pid: dispatcher_pid,
              topic: topic,
              demo_timer: timer
            )

          {:error, reason} ->
            Logger.warning("Demo #{component.name} failed: #{inspect(reason)}")
            assign(socket, demo_error: "Failed to start demo")
        end
      rescue
        e ->
          Logger.warning("Demo #{component.name} failed: #{Exception.message(e)}")

          assign(socket, demo_error: "Failed to start demo")
      catch
        :exit, reason ->
          Logger.warning("Demo #{component.name} exit: #{inspect(reason)}")
          assign(socket, demo_error: "Failed to start demo")
      end
    else
      socket
    end
  end

  @doc "Stops the running demo lifecycle and cleans up."
  def stop_demo(socket) do
    if socket.assigns[:demo_timer] do
      Process.cancel_timer(socket.assigns.demo_timer)
    end

    if socket.assigns[:lifecycle_pid] do
      try do
        Lifecycle.stop(socket.assigns.lifecycle_pid)
      catch
        :exit, _ -> :ok
      end
    end

    if socket.assigns[:topic] do
      Phoenix.PubSub.unsubscribe(Raxol.PubSub, socket.assigns.topic)
    end

    assign(socket,
      lifecycle_pid: nil,
      dispatcher_pid: nil,
      topic: nil,
      demo_timer: nil
    )
  end

  @doc """
  Handles a `{:render_update, html}` or `{:render_update, html, anim_css}`
  message from the Lifecycle by flipping the hook on and pushing the frame.

  When `:auto_focus` is set on the socket and this is the first frame after
  the terminal has been idle (terminal_html was false), also pushes a focus
  event so the cursor lands on real demo content rather than the spinner.
  LiveViews that should not auto-steal focus (e.g. LandingLive, where the
  user is reading other content) simply do not set `:auto_focus`.
  """
  def render_update(socket, html) do
    was_idle = !socket.assigns[:terminal_html]
    auto_focus = Map.get(socket.assigns, :auto_focus, false)

    socket =
      socket
      |> assign(:terminal_html, true)
      |> push_event("terminal_html", %{html: html})

    if was_idle and auto_focus do
      push_event(socket, "focus_terminal", %{})
    else
      socket
    end
  end

  @doc """
  Asks the RaxolTerminal hook to focus its element. Most callers should
  rely on the auto-focus path in `render_update/2` instead; this is here
  for explicit user-driven focus (e.g. a "Focus terminal" button).
  """
  def focus_terminal(socket) do
    push_event(socket, "focus_terminal", %{})
  end

  @doc """
  Handles the `:demo_timeout` message. Stops the lifecycle and sets an error
  message; callers that want the error pushed through the hook should pipe
  the result through `maybe_push_error/1`.
  """
  def demo_timeout(socket) do
    socket
    |> stop_demo()
    |> assign(:demo_error, "Session timed out. Click Retry to restart.")
    |> maybe_push_error()
  end

  @doc """
  Handles `{:DOWN, _ref, :process, pid, reason}`. Returns the socket
  unchanged if the down pid isn't the tracked lifecycle.
  """
  def lifecycle_down(socket, pid, reason) do
    if pid == socket.assigns[:lifecycle_pid] do
      Logger.warning("Demo lifecycle crashed: #{inspect(reason)}")

      socket
      |> assign(lifecycle_pid: nil, demo_error: "Demo crashed. Click Retry.")
      |> maybe_push_error()
    else
      socket
    end
  end

  @doc """
  Once the terminal hook owns display (terminal_html=true), push subsequent
  state changes through it instead of patching template DOM. Avoids
  morphdom contention with the hook's innerHTML replacement.
  """
  def maybe_push_reset(socket) do
    if socket.assigns[:terminal_html] do
      push_event(socket, "terminal_reset", %{})
    else
      assign(socket, :terminal_html, false)
    end
  end

  @doc """
  Pushes a demo_error through the terminal hook when the hook owns display.
  No-op otherwise (the template renders the error itself).
  """
  def maybe_push_error(socket) do
    if socket.assigns[:terminal_html] && socket.assigns[:demo_error] do
      push_event(socket, "terminal_error", %{message: socket.assigns.demo_error})
    else
      socket
    end
  end

  @doc """
  Fast per-keystroke dispatch path.

  Reads the cached `dispatcher_pid` from socket assigns (primed once by
  `start_demo/3`) and casts the event directly, skipping the
  `GenServer.call(lifecycle, :get_full_state)` roundtrip that the previous
  implementation did on every key.

  Falls back to the slow lookup if the cache is empty (e.g. the cache
  failed to prime, or the LV was upgraded mid-session).
  """
  def dispatch_event(socket, event) do
    case socket.assigns[:dispatcher_pid] do
      dpid when is_pid(dpid) ->
        GenServer.cast(dpid, {:dispatch, event})
        socket

      _ ->
        case socket.assigns[:lifecycle_pid] do
          pid when is_pid(pid) ->
            case fetch_dispatcher_pid(pid) do
              dpid when is_pid(dpid) ->
                GenServer.cast(dpid, {:dispatch, event})
                assign(socket, :dispatcher_pid, dpid)

              _ ->
                socket
            end

          _ ->
            socket
        end
    end
  end

  @doc """
  Legacy slow dispatch: resolves the dispatcher pid by calling into the
  Lifecycle GenServer on every invocation. Kept for callers that only
  hold the Lifecycle pid (e.g. server-side test harness paths). Prefer
  `dispatch_event/2` from a LiveView context.
  """
  def dispatch_to_lifecycle(pid, event) do
    case fetch_dispatcher_pid(pid) do
      dpid when is_pid(dpid) ->
        GenServer.cast(dpid, {:dispatch, event})

      _ ->
        :ok
    end
  end

  # Asks the Lifecycle GenServer for its dispatcher pid. Returns nil if
  # the lifecycle is gone, replies with unexpected shape, or times out.
  defp fetch_dispatcher_pid(lifecycle_pid) do
    case GenServer.call(lifecycle_pid, :get_full_state, 5_000) do
      %{dispatcher_pid: dpid} when is_pid(dpid) -> dpid
      _ -> nil
    end
  rescue
    e ->
      Logger.debug("fetch_dispatcher_pid failed: #{Exception.message(e)}")
      nil
  catch
    :exit, reason ->
      Logger.debug("fetch_dispatcher_pid exit: #{inspect(reason)}")
      nil
  end
end
