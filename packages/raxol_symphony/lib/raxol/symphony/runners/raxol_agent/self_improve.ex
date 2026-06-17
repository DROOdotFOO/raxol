defmodule Raxol.Symphony.Runners.RaxolAgent.SelfImprove do
  @moduledoc """
  Opt-in after-turn self-improvement for the Symphony agent runner.

  When the runner config declares an `agent.module` that is a `use Raxol.Agent`
  module with `self_improve/0` enabled, this fires `Raxol.Agent.Turn.after_turn/4`
  on each completed turn: the module's curation reviewer authors skills and
  memory, the user model refreshes, and the session-search index is fed. It runs
  alongside the runner's existing event forwarding, pause detection, policies, and
  sandboxes without touching them, and is a no-op unless configured.

  The turn's collected events (Symphony's forwarded payloads) are mapped back to
  `Conversation.Item`-shaped maps so the reviewer can gate (on tool-call count and
  errors) and read the transcript.

  ## Config (`runner.agent`)

    * `:module` -- a `use Raxol.Agent` module declaring providers + `self_improve`
    * `:self_improve_opts` -- a map of running-instance opts merged into the
      `Turn` context/effects: `:memory_opts`, `:skills_opts`, `:user_model`,
      `:session_search`, `:user_id`
  """

  require Logger

  @compile {:no_warn_undefined, Raxol.Agent.Turn}

  @doc "Whether after-turn self-improvement is configured and available."
  @spec configured?(map() | term()) :: boolean()
  def configured?(config) do
    turn_loaded?() and enabled_module?(module(config))
  end

  @doc """
  Fire the after-turn self-improvement effects for a completed turn, given the
  turn's forwarded event payloads. A no-op (and never raises) when not configured.
  """
  @spec fire(map() | term(), term(), [map()]) :: :ok
  def fire(config, issue, legacy_events) do
    if configured?(config) do
      run(module(config), opts(config, issue), legacy_events)
    end

    :ok
  rescue
    error ->
      Logger.warning("symphony self-improve hook failed: #{inspect(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("symphony self-improve hook exited: #{inspect(reason)}")
      :ok
  end

  defp run(mod, opts, legacy_events) do
    context = Raxol.Agent.Turn.build_context(mod, opts)
    items = events_to_items(legacy_events, Keyword.get(opts, :agent_id, "symphony"))
    Raxol.Agent.Turn.after_turn(mod, items, context, opts)
  end

  @doc """
  Map Symphony's forwarded event payloads to `Conversation.Item`-shaped maps:
  text deltas concatenate into one assistant `:message`, tool events become
  `:tool_call` / `:tool_result`, and a failure becomes `:error`. Each item gets
  the `conversation_id` and a unique `seq` the session-search index needs.
  """
  @spec events_to_items([map()], String.t()) :: [map()]
  def events_to_items(legacy_events, conversation_id) do
    {text, items} = Enum.reduce(legacy_events, {[], []}, &fold_event/2)

    (Enum.reverse(items) ++ message_item(text))
    |> Enum.map(&with_identity(&1, conversation_id))
  end

  defp fold_event(event, {text, items}) do
    case Map.get(event, :event) do
      :text_delta -> {[Map.get(event, :message, "") | text], items}
      :tool_use -> {text, [tool_call_item(event) | items]}
      :tool_result -> {text, [tool_result_item(event) | items]}
      :turn_failed -> {text, [error_item(event) | items]}
      _ -> {text, items}
    end
  end

  defp with_identity(item, conversation_id) do
    seq = :erlang.unique_integer([:monotonic, :positive])

    Map.merge(item, %{conversation_id: conversation_id, seq: seq, id: "#{conversation_id}:#{seq}"})
  end

  defp tool_call_item(event) do
    payload = Map.get(event, :payload, %{})

    %{
      type: :tool_call,
      data: %{
        name: Map.get(payload, :name),
        arguments: Map.get(payload, :arguments, %{}),
        id: Map.get(payload, :id)
      }
    }
  end

  defp tool_result_item(event) do
    payload = Map.get(event, :payload, %{})

    %{
      type: :tool_result,
      data: %{name: Map.get(payload, :name), result: Map.get(payload, :result)}
    }
  end

  defp error_item(event), do: %{type: :error, data: %{reason: Map.get(event, :message)}}

  defp message_item([]), do: []

  defp message_item(text_parts) do
    content = text_parts |> Enum.reverse() |> Enum.join("")
    [%{type: :message, data: %{role: :assistant, content: content}}]
  end

  # -- config -----------------------------------------------------------------

  defp opts(config, issue) do
    agent = agent(config)
    issue_id = issue_id(issue)

    [agent_id: issue_id, user_id: issue_id]
    |> Keyword.merge(self_improve_opts(agent))
  end

  defp self_improve_opts(agent) do
    agent |> Map.get(:self_improve_opts, %{}) |> Map.new() |> Map.to_list()
  end

  defp module(config), do: config |> agent() |> Map.get(:module)

  defp agent(%{runner: %{agent: agent}}) when is_map(agent), do: agent
  defp agent(_config), do: %{}

  defp issue_id(%{id: id}), do: to_string(id)
  defp issue_id(_issue), do: nil

  defp enabled_module?(mod) when is_atom(mod) and not is_nil(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :self_improve, 0) and
      match?(%{enabled: true}, mod.self_improve())
  end

  defp enabled_module?(_mod), do: false

  defp turn_loaded?, do: Code.ensure_loaded?(Raxol.Agent.Turn)
end
