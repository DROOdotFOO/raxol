defmodule Raxol.Agent.Memory.Manager do
  @moduledoc """
  Pure helpers that weave a memory provider into an agent turn.

  The provider is the normalized form `{module, opts}` (or `nil` when memory is
  disabled). `enrich_messages/3` prefetches memories relevant to the current
  query and injects them as a system message, kept after any leading static
  system messages so a cacheable system prefix is undisturbed. Memory failures
  degrade to a no-op so a backend issue never fails an agent turn.

  Writes are explicit (the `memory_remember` action). Automatic post-turn
  capture is a documented future extension, not wired here.
  """

  @type provider :: {module(), keyword()} | nil

  @doc "Inject relevant memories into `messages` for the given query."
  @spec enrich_messages([map()], provider(), String.t()) :: [map()]
  def enrich_messages(messages, nil, _query), do: messages

  def enrich_messages(messages, {mod, opts}, query) when is_atom(mod) do
    case safe_block(mod, opts, query) do
      nil -> messages
      block -> inject_after_system(messages, %{role: :system, content: block})
    end
  end

  def enrich_messages(messages, _provider, _query), do: messages

  defp safe_block(mod, opts, query) do
    mod.build_system_prompt(Keyword.put(opts, :query, query))
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp inject_after_system(messages, mem_msg) do
    {system, rest} = Enum.split_while(messages, &(Map.get(&1, :role) == :system))
    Enum.concat([system, [mem_msg], rest])
  end
end
