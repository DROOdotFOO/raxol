defmodule Raxol.Gateway.Handler.Lifecycle do
  @moduledoc """
  A `Raxol.Gateway.Handler` that runs a full TEA app per chat under
  `environment: :gateway`.

  `init/2` starts a `Raxol.Core.Runtime.Lifecycle` for the configured
  `:app_module`. The `:gateway` environment starts no terminal driver and no
  plugin manager, and registers no process names, so any number of chats can
  run the same app module concurrently. Each inbound gateway event is
  translated to a Raxol event, dispatched into the app's update cycle, and
  the reply is the app's next rendered frame as plain text (the engine
  delivers frames through an `io_writer` closure pointing at the session
  process).

  Requires the optional `:raxol` dependency; `init/2` returns
  `{:error, :raxol_not_loaded}` without it.

  ## Options

    * `:app_module` (required) - the TEA app module
    * `:width` / `:height` - frame dimensions (default 80x24)
    * `:render_timeout_ms` - budget for the post-event fold barrier and the
      synchronous render (default 5000); on timeout the event is absorbed
      with no reply
    * `:event_fn` - `(gateway_event -> raxol_event | nil)`; default maps
      `%{text: t}` to a char key event (single grapheme) or a paste event,
      mirroring the Telegram input adapter. `nil` skips the event.
    * `:format_fn` - `(render_data -> binary | nil)`; default renders the
      delivered buffer to plain text. `nil` (or an empty result) skips the
      reply.
    * `:lifecycle_opts` - extra options appended to
      `Raxol.Core.Runtime.Lifecycle.start_link/2`

  ## Turn semantics

  The handler runs inside the per-chat `Raxol.Gateway.Session` process, so
  the render `io_writer` targets that process. A turn is collected
  deterministically: stale frames (startup renders, a late frame from a
  previous turn) are flushed, the event is cast to the dispatcher, a `:sys`
  barrier confirms the model fold, and a synchronous engine render produces
  the reply frame (the newest wins if several arrive). Frames the app
  renders BETWEEN turns are consumed and discarded by the session's
  catch-all `handle_info` -- a chat surface replies to messages;
  spontaneous pushes are `Raxol.Gateway.Delivery`'s job.

  ## Teardown

  The Lifecycle GenServer is linked to the session, but a session's idle
  timeout is a `:normal` exit, which does not propagate over links. The
  handler's `terminate/2` (invoked by the session on clean stops) stops the
  Lifecycle explicitly so per-chat apps never outlive their chat.
  """

  @behaviour Raxol.Gateway.Handler

  @compile {:no_warn_undefined, [Raxol.Core.Runtime.Lifecycle]}

  require Logger

  alias Raxol.Core.Events.Event

  @default_width 80
  @default_height 24
  @default_render_timeout_ms 5_000

  @impl true
  @spec init(Raxol.Gateway.Route.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def init(_route, opts) do
    app_module = Keyword.fetch!(opts, :app_module)

    if Code.ensure_loaded?(Raxol.Core.Runtime.Lifecycle) do
      start_app(app_module, opts)
    else
      {:error, :raxol_not_loaded}
    end
  end

  @impl true
  @spec handle_event(term(), map()) :: {:reply, String.t(), map()} | {:noreply, map()}
  def handle_event(event, state) do
    with pid when is_pid(pid) <- state.dispatcher_pid,
         raxol_event when not is_nil(raxol_event) <- state.event_fn.(event) do
      dispatch_and_collect(raxol_event, state)
    else
      _ -> {:noreply, state}
    end
  end

  @impl true
  @spec terminate(term(), map()) :: :ok
  def terminate(_reason, state) do
    stop_lifecycle(state.lifecycle_pid)
  end

  # -- Private --

  defp start_app(app_module, opts) do
    case Raxol.Core.Runtime.Lifecycle.start_link(app_module, lifecycle_opts(opts)) do
      {:ok, lifecycle_pid} -> {:ok, build_state(app_module, lifecycle_pid, opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lifecycle_opts(opts) do
    session_pid = self()

    io_writer = fn render_data ->
      send(session_pid, {__MODULE__, :render, render_data})
    end

    [
      environment: :gateway,
      width: Keyword.get(opts, :width, @default_width),
      height: Keyword.get(opts, :height, @default_height),
      io_writer: io_writer
    ] ++ Keyword.get(opts, :lifecycle_opts, [])
  end

  defp build_state(app_module, lifecycle_pid, opts) do
    {dispatcher_pid, engine_pid} = discover_pids(lifecycle_pid)

    if is_nil(dispatcher_pid) do
      Logger.warning(
        "gateway lifecycle handler for #{inspect(app_module)}: " <>
          "dispatcher_pid is nil, events will be dropped"
      )
    end

    %{
      lifecycle_pid: lifecycle_pid,
      dispatcher_pid: dispatcher_pid,
      engine_pid: engine_pid,
      render_timeout_ms: Keyword.get(opts, :render_timeout_ms, @default_render_timeout_ms),
      event_fn: Keyword.get(opts, :event_fn, &default_event/1),
      format_fn: Keyword.get(opts, :format_fn, &default_format/1)
    }
  end

  defp discover_pids(lifecycle_pid) do
    case GenServer.call(lifecycle_pid, :get_full_state, 5_000) do
      %{dispatcher_pid: pid} = full -> {pid, Map.get(full, :rendering_engine_pid)}
      _ -> {nil, nil}
    end
  catch
    # Lifecycle may not respond if it is still initializing or crashed.
    :exit, {:timeout, _} -> {nil, nil}
    :exit, {:noproc, _} -> {nil, nil}
  end

  defp dispatch_and_collect(raxol_event, state) do
    flush_renders()
    GenServer.cast(state.dispatcher_pid, {:dispatch, raxol_event})

    case collect_frame(state) do
      {:ok, render_data} -> reply(render_data, state)
      :none -> {:noreply, state}
    end
  end

  # Deterministic collection (same-node sends enqueue in causal order): the
  # :sys barrier confirms the dispatcher folded the event into the model,
  # the synchronous engine render then draws that model, and the engine
  # sends the frame to the io_writer before replying -- so by the time the
  # call returns, the frame is already in the mailbox.
  defp collect_frame(%{engine_pid: engine} = state) when is_pid(engine) do
    with :ok <- barrier(state.dispatcher_pid, state.render_timeout_ms),
         :ok <- sync_render(engine, state.render_timeout_ms) do
      take_newest_frame()
    end
  end

  # No engine pid discovered: best effort, wait for the async frame.
  defp collect_frame(state) do
    receive do
      {__MODULE__, :render, render_data} -> {:ok, drain_latest(render_data)}
    after
      state.render_timeout_ms -> :none
    end
  end

  defp barrier(dispatcher_pid, timeout_ms) do
    _ = :sys.get_state(dispatcher_pid, timeout_ms)
    :ok
  catch
    :exit, _reason -> :none
  end

  defp sync_render(engine_pid, timeout_ms) do
    _ = GenServer.call(engine_pid, :render_frame_sync, timeout_ms)
    :ok
  catch
    :exit, _reason -> :none
  end

  defp take_newest_frame do
    receive do
      {__MODULE__, :render, render_data} -> {:ok, drain_latest(render_data)}
    after
      0 -> :none
    end
  end

  defp reply(render_data, state) do
    case state.format_fn.(render_data) do
      text when is_binary(text) and text != "" -> {:reply, text, state}
      _ -> {:noreply, state}
    end
  end

  # A frame from a previous turn can arrive after that turn's receive timed
  # out; without a flush it would be mistaken for this turn's response.
  defp flush_renders do
    receive do
      {__MODULE__, :render, _stale} -> flush_renders()
    after
      0 -> :ok
    end
  end

  defp drain_latest(latest) do
    receive do
      {__MODULE__, :render, data} -> drain_latest(data)
    after
      0 -> latest
    end
  end

  defp default_event(%{text: text}) when is_binary(text) do
    case String.graphemes(String.trim(text)) do
      [] -> nil
      [char] -> Event.new(:key, %{key: :char, char: char})
      _ -> Event.new(:paste, %{text: String.trim(text)})
    end
  end

  defp default_event(_event), do: nil

  defp default_format(%{buffer: buffer}), do: buffer_to_text(buffer)
  defp default_format(text) when is_binary(text), do: text
  defp default_format(_render_data), do: nil

  # Map patterns only: the buffer struct lives in raxol_terminal, across the
  # package boundary.
  defp buffer_to_text(%{cells: cells}) when is_list(cells) do
    cells
    |> Enum.map(&row_to_text/1)
    |> trim_trailing_empty()
    |> Enum.join("\n")
  end

  defp buffer_to_text(_buffer), do: ""

  defp row_to_text(line) when is_list(line) do
    line
    |> Enum.map_join("", fn
      %{char: char} when is_binary(char) -> char
      _ -> " "
    end)
    |> String.trim_trailing()
  end

  defp row_to_text(_line), do: ""

  defp trim_trailing_empty(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  defp stop_lifecycle(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1_000)
      catch
        # Any exit here means the Lifecycle is down or already going down:
        # noproc/normal races, its :shutdown teardown cascade overriding the
        # requested :normal (the exit arrives MFA-wrapped), or a stop that
        # outlived the wait budget after the request was delivered. This
        # teardown's only goal is "not leaked", so all of these are success.
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp stop_lifecycle(_pid), do: :ok
end
