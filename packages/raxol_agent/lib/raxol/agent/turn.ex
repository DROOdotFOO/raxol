defmodule Raxol.Agent.Turn do
  @moduledoc """
  Drives one self-improving agent turn for an agent module.

  This is where the memory, skills, and self-improvement pieces meet. `run/3`
  assembles the tool context from the agent module's callbacks
  (`memory_provider`/`memory_providers`, `skills_provider`, `self_improve`), runs
  the framework ReAct loop (`Raxol.Agent.Stream.react/2`), records the turn into a
  `Raxol.Agent.Conversation.Log`, and then fires the after-turn side effects:
  background curation (`Raxol.Agent.SelfImprove`), a user-model refresh, and a
  session-search index update.

  The agent module declares *which* providers it wants; the caller supplies the
  *running instances* through opts (store server names, the UserModel and
  SessionSearch servers).

  ## Options

    * `:backend` (required) -- the `AIBackend` for the turn
    * `:backend_opts` -- extra opts passed to the backend
    * `:log` (required) -- the `Conversation.Log` server
    * `:conversation_id` (required)
    * `:response_id` -- tags recorded items with the turn id
    * `:agent_id` -- partitions memory
    * `:user_id` -- keys the user model and its context injection
    * `:memory_opts` / `:skills_opts` -- merged into the provider contexts
      (notably `:server` when a store runs under a non-default name)
    * `:user_model` -- the `UserModel` server; enables user-context injection and
      a background refresh after the turn
    * `:session_search` -- the `SessionSearch` server; enables the
      `session_search` action and indexes the turn's items
    * `:max_iterations`
  """

  alias Raxol.Agent.Conversation.Recorder
  alias Raxol.Agent.Memory
  alias Raxol.Agent.Memory.SessionSearch
  alias Raxol.Agent.SelfImprove
  alias Raxol.Agent.Skills
  alias Raxol.Agent.Stream
  alias Raxol.Agent.UserModel

  @spec run(module(), String.t() | [map()], keyword()) :: {:ok, [map()]}
  def run(agent_module, prompt, opts) do
    log = Keyword.fetch!(opts, :log)
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    context = build_context(agent_module, opts)

    react_opts =
      [
        backend: Keyword.fetch!(opts, :backend),
        backend_opts: Keyword.get(opts, :backend_opts, []),
        actions: actions(agent_module, opts),
        context: context
      ]
      |> maybe_put(:max_iterations, Keyword.get(opts, :max_iterations))

    {:ok, items} =
      prompt
      |> Stream.react(react_opts)
      |> then(
        &Recorder.record_stream(log, conversation_id, &1,
          response_id: Keyword.get(opts, :response_id)
        )
      )

    after_turn(agent_module, items, context, opts)
    {:ok, items}
  end

  @doc """
  Assemble the tool context (`:memory`, `:skills`, `:user_context`,
  `:session_search`) from the agent module's callbacks and the running instances
  in `opts`. Keys are present only when their capability is configured.
  """
  @spec build_context(module(), keyword()) :: map()
  def build_context(agent_module, opts) do
    agent_id = Keyword.get(opts, :agent_id)

    %{}
    |> maybe_put(:memory, memory_context(agent_module, agent_id, opts))
    |> maybe_put(:skills, skills_context(agent_module, opts))
    |> maybe_put(:user_context, user_context(opts))
    |> maybe_put(:session_search, session_search_context(opts))
  end

  @doc """
  Run the after-turn side effects for a recorded turn: trigger curation, refresh
  the user model in the background, and feed the session-search index.
  """
  @spec after_turn(module(), [map()], map(), keyword()) :: :ok
  def after_turn(agent_module, items, context, opts) do
    writers = %{memory: Map.get(context, :memory), skills: Map.get(context, :skills)}
    SelfImprove.after_turn(items, writers, call(agent_module, :self_improve, nil))

    maybe_refresh_user_model(items, opts)
    maybe_index_session(items, opts)
    :ok
  end

  # -- after-turn effects -----------------------------------------------------

  defp maybe_refresh_user_model(items, opts) do
    with server when not is_nil(server) <- Keyword.get(opts, :user_model),
         user_id when not is_nil(user_id) <- Keyword.get(opts, :user_id) do
      UserModel.refresh_async(server, user_id, items)
    end
  end

  defp maybe_index_session(items, opts) do
    case Keyword.get(opts, :session_search) do
      nil -> :ok
      server -> SessionSearch.index(server, items)
    end
  end

  # -- context assembly -------------------------------------------------------

  defp memory_context(agent_module, agent_id, opts) do
    extra = Keyword.get(opts, :memory_opts, [])
    providers = call(agent_module, :memory_providers, [])

    case Memory.stack_context(providers, agent_id, extra) do
      nil -> Memory.provider_context(call(agent_module, :memory_provider, nil), agent_id, extra)
      stack -> stack
    end
  end

  defp skills_context(agent_module, opts) do
    case call(agent_module, :skills_provider, nil) do
      nil -> nil
      provider -> Skills.provider_context(provider, Keyword.get(opts, :skills_opts, []))
    end
  end

  defp user_context(opts) do
    with server when not is_nil(server) <- Keyword.get(opts, :user_model),
         user_id when not is_nil(user_id) <- Keyword.get(opts, :user_id) do
      {UserModel, [server: server, user_id: user_id]}
    else
      _ -> nil
    end
  end

  defp session_search_context(opts) do
    case Keyword.get(opts, :session_search) do
      nil -> nil
      server -> {SessionSearch, [server: server]}
    end
  end

  defp actions(agent_module, opts) do
    base = call(agent_module, :available_actions, [])

    if Keyword.get(opts, :session_search),
      do: base ++ [Raxol.Agent.Actions.SessionSearch],
      else: base
  end

  defp call(mod, fun, default) do
    if function_exported?(mod, fun, 0), do: apply(mod, fun, []), else: default
  end

  defp maybe_put(collection, _key, nil), do: collection
  defp maybe_put(map, key, value) when is_map(map), do: Map.put(map, key, value)
  defp maybe_put(opts, key, value) when is_list(opts), do: Keyword.put(opts, key, value)
end
