defmodule Raxol.Gateway.Handler.Agent do
  @moduledoc """
  A `Raxol.Gateway.Handler` backed by the Raxol agent runtime.

  Each inbound `%{text: text}` event becomes one synchronous agent turn via
  `Raxol.Agent.Stream.run/2`; the collected answer is returned as the rendered
  reply. Any other event shape is ignored (`:noreply`). Adapters that want a
  chat handled by an agent normalize their text messages to `%{text: binary}`.

  Requires the optional `:raxol_agent` dependency; `init/2` returns
  `{:error, :raxol_agent_not_loaded}` without it.

  ## Options

    * `:system_prompt` -- passed to every turn (never stored in history, so
      trimming cannot drop it)
    * `:max_history` -- max messages kept (user + assistant), default 40
    * `:agent_opts` -- options forwarded to `Raxol.Agent.Stream.run/2`
      (`:backend`, `:backend_opts`, `:executor`, `:provider`, `:model`, ...).
      When neither `:backend` nor `:executor` is pinned, `auto_provider: true`
      is added so the executor resolves from the environment (1Password ref ->
      provider env vars -> `AI_API_KEY`); resolution failure falls through to
      the Mock backend rather than crashing.
    * `:max_turns_per_window` -- per-chat fixed-window turn cap. Unset means
      no throttle. When the cap is hit, the event is answered with a short
      rate-limit notice: no backend call is made and history is untouched,
      so a burst cannot run up backend spend or evict context.
    * `:window_ms` -- throttle window length in milliseconds (default 60000).
      A window starts at the first allowed turn after the previous window
      expires.
    * `:now_fn` -- millisecond monotonic clock used by the throttle,
      injectable for deterministic tests.

  ## Turn semantics

  A turn runs synchronously inside the per-chat `Raxol.Gateway.Session`
  process: events arriving mid-turn queue in the session mailbox, and the
  session's `:idle_timeout` should comfortably exceed the longest expected
  turn. A failed turn (error tuple or a crash inside the backend) keeps the
  user message in history and replies with a short error message; the full
  reason is logged.

  Every allowed text event is one backend call. The throttle bounds backend
  spend per chat; it does not authenticate anyone, so still gate the inbound
  feed (`Raxol.Gateway.Pairing.authorize/2`, platform allowlists) before
  routing untrusted chats at a paid backend.
  """

  @behaviour Raxol.Gateway.Handler

  @compile {:no_warn_undefined, [Raxol.Agent.Stream]}

  require Logger

  alias Raxol.Core.ErrorHandling

  @default_max_history 40
  @default_window_ms 60_000

  @impl true
  @spec init(Raxol.Gateway.Route.t(), keyword()) ::
          {:ok, map()} | {:error, :raxol_agent_not_loaded}
  def init(_route, opts) do
    if Code.ensure_loaded?(Raxol.Agent.Stream) do
      agent_opts = default_agent_opts(Keyword.get(opts, :agent_opts, []))

      warn_if_unresolved(
        agent_opts,
        Keyword.get(opts, :resolve_probe, &default_probe/1)
      )

      {:ok,
       %{
         messages: [],
         system_prompt: Keyword.get(opts, :system_prompt),
         max_history: Keyword.get(opts, :max_history, @default_max_history),
         agent_opts: agent_opts,
         throttle: init_throttle(opts),
         now_fn: Keyword.get(opts, :now_fn, &default_now/0)
       }}
    else
      {:error, :raxol_agent_not_loaded}
    end
  end

  @impl true
  @spec handle_event(term(), map()) ::
          {:reply, String.t(), map()} | {:noreply, map()}
  def handle_event(%{text: text}, state) when is_binary(text) and text != "" do
    case check_throttle(state) do
      {:allow, state} -> run_allowed_turn(text, state)
      :deny -> {:reply, "Rate limited. Try again shortly.", state}
    end
  end

  def handle_event(_event, state), do: {:noreply, state}

  defp run_allowed_turn(text, state) do
    messages =
      append_capped(
        state.messages,
        %{role: :user, content: text},
        state.max_history
      )

    case run_turn(messages, state) do
      {:ok, content} ->
        {:reply, content,
         %{
           state
           | messages:
               append_capped(
                 messages,
                 %{role: :assistant, content: content},
                 state.max_history
               )
         }}

      {:error, reason} ->
        Logger.warning("gateway agent turn failed: #{inspect(reason)}")
        {:reply, error_text(reason), %{state | messages: messages}}
    end
  end

  defp init_throttle(opts) do
    case Keyword.get(opts, :max_turns_per_window) do
      nil ->
        nil

      max when is_integer(max) and max > 0 ->
        %{
          max: max,
          window_ms: Keyword.get(opts, :window_ms, @default_window_ms),
          count: 0,
          window_start: nil
        }
    end
  end

  # Fixed window: a failed backend turn still counts (it consumed a call).
  defp check_throttle(%{throttle: nil} = state), do: {:allow, state}

  defp check_throttle(%{throttle: throttle} = state) do
    now = state.now_fn.()

    cond do
      throttle.window_start == nil or
          now - throttle.window_start >= throttle.window_ms ->
        {:allow, %{state | throttle: %{throttle | window_start: now, count: 1}}}

      throttle.count < throttle.max ->
        {:allow, %{state | throttle: %{throttle | count: throttle.count + 1}}}

      true ->
        :deny
    end
  end

  defp default_now, do: System.monotonic_time(:millisecond)

  # A backend that raises/exits mid-enumeration would otherwise crash the
  # session and drop this chat's events for the router's cooldown window.
  defp run_turn(messages, state) do
    run_opts = put_system_prompt(state.agent_opts, state.system_prompt)

    result =
      ErrorHandling.safe_call(fn ->
        messages
        |> Raxol.Agent.Stream.run(run_opts)
        |> Raxol.Agent.Stream.collect()
      end)

    case result do
      {:ok, {:ok, %{content: content}}} when is_binary(content) ->
        {:ok, content}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:unexpected_turn_result, other}}

      {:error, crash} ->
        {:error, {:crashed, crash}}
    end
  end

  # auto_provider only when the caller pinned nothing: a resolved environment
  # executor wins over :backend inside Stream, so defaulting it unconditionally
  # would let a machine's AI_API_KEY hijack an explicitly pinned backend.
  defp default_agent_opts(opts) do
    if Keyword.has_key?(opts, :backend) or Keyword.has_key?(opts, :executor) do
      opts
    else
      Keyword.put_new(opts, :auto_provider, true)
    end
  end

  defp put_system_prompt(opts, nil), do: opts

  defp put_system_prompt(opts, prompt),
    do: Keyword.put_new(opts, :system_prompt, prompt)

  # An unresolved auto_provider silently answers from the Mock backend; make
  # that loud once at session start. :resolve_probe is the injectable seam so
  # tests never touch real credential resolution (which may shell out to op).
  defp warn_if_unresolved(agent_opts, probe) do
    if Keyword.get(agent_opts, :auto_provider, false) and
         is_nil(probe.(agent_opts)) do
      Logger.warning(
        "no agent provider resolved from the environment; " <>
          "replies will come from the Mock backend"
      )
    end

    :ok
  end

  defp default_probe(agent_opts),
    do: Raxol.Agent.Stream.resolve_executor(agent_opts)

  # Trim from the front, then drop any leading assistant messages: several
  # providers reject a history whose first message is not a user turn.
  defp append_capped(messages, message, max) do
    [message | Enum.reverse(messages)]
    |> Enum.take(max)
    |> Enum.reverse()
    |> Enum.drop_while(&(&1.role == :assistant))
  end

  defp error_text(reason) when is_atom(reason),
    do: "Agent error (#{reason}). Try again."

  defp error_text(_reason), do: "Agent error. Try again."
end
