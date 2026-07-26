defmodule Raxol.Gateway.Adapter.Email.Inbox do
  @moduledoc """
  Polls a mailbox for new messages and hands each raw message to a
  caller-supplied function.

  This is the inbound *feed* for `Raxol.Gateway.Adapter.Email`: the stateful
  loop that turns a mailbox into a stream of raw RFC822 messages. It is
  transport-agnostic on purpose -- `gen_smtp` only speaks SMTP, and the mailbox
  a deployment reads (IMAP, POP3, the Gmail API, or an SMTP listener) is its
  choice, so the fetch is injected. There is no default `:fetch_fn`, the same
  way `Raxol.Gateway.Pipeline.Transcribe` has no default audio fetch: the
  transport is environment-specific.

  It mirrors `Raxol.Telegram.UpdatePoller`: sink-agnostic (`:on_message`
  decides what a message means), authorize-before-route in the sink, and
  exponential backoff on fetch errors. A gateway wiring:

      {:ok, store} = ThreadStore.start_link(name: MyThreads)

      Raxol.Gateway.Adapter.Email.Inbox.start_link(
        fetch_fn: fn cursor -> MyImap.fetch_since(cursor) end,
        on_message: fn raw ->
          case Raxol.Gateway.Adapter.Email.normalize_event(raw) do
            {:ok, route, event} ->
              # NOTE: `route` is keyed on the unauthenticated `From` header.
              # authorize is only meaningful behind an MTA that verifies the
              # sender (SPF/DKIM/DMARC) -- see the `Adapter.Email` "Security"
              # section. A raw feed with no upstream auth is anonymous.
              with :allow <- Raxol.Gateway.Pairing.authorize(MyPairing, route) do
                Raxol.Gateway.Adapter.Email.ThreadStore.record_event(store, route, event)
                Raxol.Gateway.SessionRouter.route(MyRouter, route, event)
              else
                :deny -> Logger.info("unauthorized sender denied")
              end

            :ignore ->
              :ok
          end
        end
      )

  ## Options

    * `:fetch_fn` (required) - `(cursor -> {:ok, [raw], next_cursor} |
      {:error, reason})`. Fetches messages newer than `cursor` and returns the
      cursor to poll from next. `cursor` starts at `:initial_cursor` (default
      `nil`). The transport owns durable cursor state (e.g. an IMAP
      UIDVALIDITY/UID checkpoint), so a restart resumes where the transport
      left off rather than re-reading the mailbox.
    * `:on_message` (required) - 1-arity function called per raw message, in
      order. A crash inside it is caught and logged; the loop continues and
      the cursor still advances, so a consumer that needs exactly-once must
      dedup on `Message-ID`.
    * `:interval_ms` - delay between polls (default 60_000). Applied after each
      completed poll, empty or not.
    * `:max_bytes` - a raw message larger than this is dropped before
      `on_message` (default 10MB), with a `Logger.warning` and
      `[:raxol_gateway, :email_inbox, :oversized]` telemetry. Bounds the memory
      `:mimemail.decode` spends parsing untrusted mail into part trees.
    * `:initial_cursor` - the cursor for the first fetch (default `nil`).
    * `:name` - optional registered name.

  ## Errors

  A `:fetch_fn` error backs off exponentially (1s doubling, capped at 60s) and
  resets on the next success. The fetch reason is logged classified only -- the
  `:fetch_fn` closure may capture mailbox credentials, so neither it nor the
  state is ever dumped (`format_status/1` redacts both).
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.Core.ErrorHandling

  @default_interval_ms 60_000
  # Inbound mail is untrusted: `:mimemail.decode` parses every part into memory,
  # so a raw message is dropped before `on_message` if it exceeds this. 10MB is
  # generous for text mail; raise `:max_bytes` for attachment-heavy mailboxes.
  @default_max_bytes 10 * 1024 * 1024
  @backoff_base_ms 1_000
  @backoff_cap_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    state = %{
      fetch_fn: Keyword.fetch!(opts, :fetch_fn),
      on_message: Keyword.fetch!(opts, :on_message),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes),
      cursor: Keyword.get(opts, :initial_cursor),
      failures: 0,
      timer: nil
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(:poll, state) do
    state = cancel_timer(state)

    case safe_fetch(state) do
      {:ok, messages, next_cursor} when is_list(messages) ->
        Enum.each(messages, &deliver(&1, state))
        {:noreply, schedule_poll(%{state | cursor: next_cursor, failures: 0}, state.interval_ms)}

      {:ok, other} ->
        backoff(state, {:unexpected_result, other})

      {:error, reason} ->
        backoff(state, reason)
    end
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # The conn/closures capture mailbox credentials: never dump the state.
  @impl GenServer
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{} = state -> %{state | fetch_fn: :redacted, on_message: :redacted}
      other -> other
    end)
  end

  defp safe_fetch(%{fetch_fn: fetch_fn, cursor: cursor}) do
    fetch_fn.(cursor)
  rescue
    error -> {:error, {:fetch_raised, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:fetch_exit, kind, reason}}
  end

  defp deliver(raw, state) do
    case raw_size(raw) do
      size when is_integer(size) and size > state.max_bytes ->
        drop_oversized(size, state.max_bytes)

      _within_limit ->
        invoke(raw, state.on_message)
    end
  end

  defp drop_oversized(size, limit) do
    :telemetry.execute(
      [:raxol_gateway, :email_inbox, :oversized],
      %{bytes: size},
      %{limit: limit}
    )

    Logger.warning("email inbox dropped oversized message (#{size} > #{limit} bytes)")
    :ok
  end

  defp invoke(raw, on_message) do
    case ErrorHandling.safe_call(fn -> on_message.(raw) end) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("email inbox on_message failed: #{inspect(reason)}")
        :ok
    end
  end

  defp raw_size(raw) when is_binary(raw), do: byte_size(raw)
  defp raw_size(%{rfc822: raw}) when is_binary(raw), do: byte_size(raw)
  defp raw_size(_other), do: nil

  defp backoff(state, reason) do
    failures = state.failures + 1
    delay = min(@backoff_base_ms * Integer.pow(2, failures - 1), @backoff_cap_ms)

    Logger.warning(
      "email inbox fetch failed (attempt #{failures}, retry in #{delay}ms): #{inspect(reason)}"
    )

    {:noreply, schedule_poll(%{state | failures: failures}, delay)}
  end

  defp schedule_poll(state, delay) do
    %{state | timer: Process.send_after(self(), :poll, delay)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end
end
