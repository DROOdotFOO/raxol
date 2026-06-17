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

  @doc """
  Append a provider's `build_user_context/1` block to the LAST user message.

  Unlike `enrich_messages/3`, which injects into the system prefix, this injects
  into the user message so a per-turn refresh leaves the cacheable system prefix
  untouched. A nil provider, an absent callback, or a failure is a no-op.
  """
  @spec enrich_user_context([map()], provider()) :: [map()]
  def enrich_user_context(messages, nil), do: messages

  def enrich_user_context(messages, {mod, opts}) when is_atom(mod) do
    case safe_user_block(mod, opts) do
      nil -> messages
      "" -> messages
      block -> append_to_last_user(messages, block)
    end
  end

  def enrich_user_context(messages, _provider), do: messages

  defp safe_user_block(mod, opts) do
    if function_exported?(mod, :build_user_context, 1) do
      mod.build_user_context(opts)
    else
      nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp append_to_last_user(messages, block) do
    last_user_index =
      messages
      |> Enum.with_index()
      |> Enum.filter(fn {msg, _i} -> Map.get(msg, :role) == :user end)
      |> List.last()

    case last_user_index do
      nil ->
        messages

      {_msg, index} ->
        List.update_at(messages, index, fn msg ->
          existing = Map.get(msg, :content, "")
          Map.put(msg, :content, existing <> "\n\n" <> block)
        end)
    end
  end
end
