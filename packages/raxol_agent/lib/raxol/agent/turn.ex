defmodule Raxol.Agent.Turn do
  @moduledoc """
  Drives one agent turn for an agent module.

  `run/3` assembles the tool context from the agent module's `skills_provider`
  callback, runs the framework ReAct loop (`Raxol.Agent.Stream.react/2`) and
  records the turn into a `Raxol.Agent.Conversation.Log`.

  The agent module declares *which* provider it wants; the caller supplies the
  *running instance* through opts (the store server name).

  ## Options

    * `:backend` (required) -- the `AIBackend` for the turn
    * `:backend_opts` -- extra opts passed to the backend
    * `:log` (required) -- the `Conversation.Log` server
    * `:conversation_id` (required)
    * `:response_id` -- tags recorded items with the turn id
    * `:skills_opts` -- merged into the skills provider context (notably
      `:server` when the store runs under a non-default name)
    * `:max_iterations`
  """

  alias Raxol.Agent.Conversation.Recorder
  alias Raxol.Agent.Skills
  alias Raxol.Agent.Stream

  @spec run(module(), String.t() | [map()], keyword()) :: {:ok, [map()]}
  def run(agent_module, prompt, opts) do
    log = Keyword.fetch!(opts, :log)
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    context = build_context(agent_module, opts)

    react_opts =
      [
        backend: Keyword.fetch!(opts, :backend),
        backend_opts: Keyword.get(opts, :backend_opts, []),
        actions: call(agent_module, :available_actions, []),
        context: context
      ]
      |> maybe_put(:max_iterations, Keyword.get(opts, :max_iterations))

    prompt
    |> Stream.react(react_opts)
    |> then(
      &Recorder.record_stream(log, conversation_id, &1,
        response_id: Keyword.get(opts, :response_id)
      )
    )
  end

  @doc """
  Assemble the tool context from the agent module's callbacks and the running
  instances in `opts`. `:skills` is present only when the agent declares a
  skills provider.
  """
  @spec build_context(module(), keyword()) :: map()
  def build_context(agent_module, opts) do
    %{}
    |> maybe_put(:skills, skills_context(agent_module, opts))
    |> Raxol.Agent.Web3.put_context()
  end

  defp skills_context(agent_module, opts) do
    case call(agent_module, :skills_provider, nil) do
      nil -> nil
      provider -> Skills.provider_context(provider, Keyword.get(opts, :skills_opts, []))
    end
  end

  defp call(mod, fun, default) do
    if function_exported?(mod, fun, 0), do: apply(mod, fun, []), else: default
  end

  defp maybe_put(collection, _key, nil), do: collection
  defp maybe_put(map, key, value) when is_map(map), do: Map.put(map, key, value)
  defp maybe_put(opts, key, value) when is_list(opts), do: Keyword.put(opts, key, value)
end
