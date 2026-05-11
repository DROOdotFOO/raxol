defmodule Raxol.Telegram.Session do
  @moduledoc """
  Per-chat Telegram session.

  Manages a Raxol Lifecycle instance for a single Telegram chat.
  Receives render callbacks via `io_writer` and sends/edits messages
  in the chat. Dispatches input events to the TEA update cycle.

  The session auto-stops after an idle timeout (default 10 minutes).
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.Telegram.OutputAdapter

  @compile {:no_warn_undefined, [Raxol.Core.Runtime.Lifecycle]}

  @default_idle_timeout 10 * 60 * 1000

  defstruct [
    :app_module,
    :chat_id,
    :lifecycle_pid,
    :dispatcher_pid,
    :idle_timeout,
    :idle_timer,
    :last_message_id,
    :last_html
  ]

  @doc """
  Dispatches an event to this session's TEA lifecycle.
  """
  @spec dispatch(pid(), Raxol.Core.Events.Event.t()) :: :ok
  def dispatch(pid, event) do
    GenServer.cast(pid, {:dispatch, event})
  end

  @doc """
  Called by the rendering backend to deliver a frame.
  The session edits the existing message or sends a new one.
  """
  @spec render(pid(), String.t(), [[map()]]) :: :ok
  def render(pid, html, keyboard) do
    GenServer.cast(pid, {:render, html, keyboard})
  end

  # -- BaseManager Callbacks --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    app_module = Keyword.fetch!(opts, :app_module)
    chat_id = Keyword.fetch!(opts, :chat_id)
    idle_timeout = Keyword.get(opts, :idle_timeout, @default_idle_timeout)

    state = %__MODULE__{
      app_module: app_module,
      chat_id: chat_id,
      idle_timeout: idle_timeout
    }

    # Start the TEA lifecycle in :telegram environment.
    # The io_writer callback is set to deliver frames back to this session.
    session_pid = self()
    {width, height} = OutputAdapter.default_size()

    io_writer = fn render_data ->
      send(session_pid, {:io_write, render_data})
    end

    case start_lifecycle(app_module, width, height, io_writer) do
      {:ok, lifecycle_pid, dispatcher_pid} ->
        timer = schedule_idle_timeout(idle_timeout)

        {:ok,
         %{
           state
           | lifecycle_pid: lifecycle_pid,
             dispatcher_pid: dispatcher_pid,
             idle_timer: timer
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:dispatch, event}, state) do
    if state.dispatcher_pid do
      GenServer.cast(state.dispatcher_pid, {:dispatch, event})
    end

    {:noreply, reset_idle_timer(state)}
  end

  def handle_manager_cast({:render, html, keyboard}, state) do
    new_state = do_send_or_edit(html, keyboard, state)
    {:noreply, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:io_write, render_data}, state) do
    {html, keyboard} = format_render_data(render_data)
    new_state = do_send_or_edit(html, keyboard, state)
    {:noreply, new_state}
  end

  def handle_manager_info(:idle_timeout, state) do
    {:stop, :normal, state}
  end

  def handle_manager_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.lifecycle_pid && Process.alive?(state.lifecycle_pid) do
      try do
        GenServer.stop(state.lifecycle_pid, :normal, 1000)
      catch
        # Process may have already exited between alive? check and stop call
        :exit, {:noproc, _} -> :ok
        :exit, {:normal, _} -> :ok
      end
    end

    :ok
  end

  # -- Private --

  # Lifecycle io_writer callback delivers render data in several shapes:
  #   - %{buffer: buffer, view_tree: tree} -- full render with widget tree
  #   - %{buffer: buffer}                 -- buffer-only render (no tree)
  #   - binary string                     -- raw text output
  #   - other                             -- fallback placeholder
  defp format_render_data(%{buffer: buffer, view_tree: view_tree}),
    do: OutputAdapter.format_message(buffer, view_tree)

  defp format_render_data(%{buffer: buffer}),
    do: OutputAdapter.format_message(buffer)

  defp format_render_data(text) when is_binary(text),
    do: {"<pre>#{OutputAdapter.escape_html(text)}</pre>", OutputAdapter.default_keyboard()}

  defp format_render_data(_),
    do: {"<pre>...</pre>", OutputAdapter.default_keyboard()}

  defp start_lifecycle(app_module, width, height, io_writer) do
    if Code.ensure_loaded?(Raxol.Core.Runtime.Lifecycle) do
      case Raxol.Core.Runtime.Lifecycle.start_link(app_module,
             environment: :telegram,
             width: width,
             height: height,
             io_writer: io_writer
           ) do
        {:ok, lifecycle_pid} ->
          # Get dispatcher pid from lifecycle state
          dispatcher_pid =
            try do
              case GenServer.call(lifecycle_pid, :get_full_state, 5000) do
                %{dispatcher_pid: pid} -> pid
                _ -> nil
              end
            catch
              # Lifecycle may not respond if it's still initializing or crashed
              :exit, {:timeout, _} -> nil
              :exit, {:noproc, _} -> nil
            end

          if is_nil(dispatcher_pid) do
            Logger.warning(
              "Telegram session for #{inspect(app_module)}: dispatcher_pid is nil, events will be dropped"
            )
          end

          {:ok, lifecycle_pid, dispatcher_pid}

        error ->
          error
      end
    else
      {:error, :lifecycle_not_available}
    end
  end

  defp do_send_or_edit(html, keyboard, state) do
    # Skip if content hasn't changed
    if html == state.last_html do
      state
    else
      message_id = send_or_edit_message(state.chat_id, html, keyboard, state.last_message_id)
      %{state | last_message_id: message_id, last_html: html}
    end
  end

  defp send_or_edit_message(chat_id, html, keyboard, last_message_id) do
    reply_markup = %{inline_keyboard: keyboard}

    if Code.ensure_loaded?(Telegex) do
      if last_message_id do
        # Edit existing message to avoid spam
        case Telegex.edit_message_text(html,
               chat_id: chat_id,
               message_id: last_message_id,
               parse_mode: "HTML",
               reply_markup: reply_markup
             ) do
          {:ok, _msg} ->
            last_message_id

          {:error, _} ->
            # Edit failed, send new message
            send_new_message(chat_id, html, reply_markup)
        end
      else
        send_new_message(chat_id, html, reply_markup)
      end
    else
      # Telegex not available, log and return nil
      last_message_id
    end
  end

  defp send_new_message(chat_id, html, reply_markup) do
    case Telegex.send_message(chat_id, html,
           parse_mode: "HTML",
           reply_markup: reply_markup
         ) do
      {:ok, msg} -> Map.get(msg, :message_id)
      {:error, _} -> nil
    end
  end

  defp schedule_idle_timeout(timeout) do
    Process.send_after(self(), :idle_timeout, timeout)
  end

  defp reset_idle_timer(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: schedule_idle_timeout(state.idle_timeout)}
  end
end
