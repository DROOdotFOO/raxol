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

  ## Turn semantics

  A turn runs synchronously inside the per-chat `Raxol.Gateway.Session`
  process: events arriving mid-turn queue in the session mailbox, and the
  session's `:idle_timeout` should comfortably exceed the longest expected
  turn. A failed turn (error tuple or a crash inside the backend) keeps the
  user message in history and replies with a short error message; the full
  reason is logged.
  """

  @behaviour Raxol.Gateway.Handler

  @compile {:no_warn_undefined, [Raxol.Agent.Stream]}

  require Logger

  alias Raxol.Core.ErrorHandling

  @default_max_history 40

  @impl true
  @spec init(Raxol.Gateway.Route.t(), keyword()) ::
          {:ok, map()} | {:error, :raxol_agent_not_loaded}
  def init(_route, opts) do
    if Code.ensure_loaded?(Raxol.Agent.Stream) do
      {:ok,
       %{
         messages: [],
         system_prompt: Keyword.get(opts, :system_prompt),
         max_history: Keyword.get(opts, :max_history, @default_max_history),
         agent_opts: default_agent_opts(Keyword.get(opts, :agent_opts, []))
       }}
    else
      {:error, :raxol_agent_not_loaded}
    end
  end

  @impl true
  @spec handle_event(term(), map()) :: {:reply, String.t(), map()} | {:noreply, map()}
  def handle_event(%{text: text}, state) when is_binary(text) and text != "" do
    messages =
      append_capped(state.messages, %{role: :user, content: text}, state.max_history)

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

  def handle_event(_event, state), do: {:noreply, state}

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
      {:ok, {:ok, %{content: content}}} when is_binary(content) -> {:ok, content}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, crash} -> {:error, {:crashed, crash}}
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
  defp put_system_prompt(opts, prompt), do: Keyword.put_new(opts, :system_prompt, prompt)

  defp append_capped(messages, message, max) do
    [message | Enum.reverse(messages)]
    |> Enum.take(max)
    |> Enum.reverse()
  end

  defp error_text(reason) when is_atom(reason), do: "Agent error (#{reason}). Try again."
  defp error_text(_reason), do: "Agent error. Try again."
end
