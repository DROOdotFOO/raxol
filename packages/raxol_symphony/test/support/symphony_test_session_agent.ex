defmodule Raxol.Symphony.TestSupport.SessionAgentSucceed do
  @moduledoc """
  TEA agent module for the Session-backed runner tests.

  On `:symphony_start`, emits one `:turn_complete` event then `:done`.
  """

  def init(_args), do: {%{session_id: nil, done?: false}, []}

  def update({:agent_message, _, {:symphony_start, payload}}, model) do
    session_id = payload.session_id

    if Code.ensure_loaded?(Raxol.Agent.SessionStreamer) do
      Raxol.Agent.SessionStreamer.emit(session_id, {:turn_complete, %{tokens: %{total: 5}}})
      Raxol.Agent.SessionStreamer.emit(session_id, {:done, %{result: :ok}})
    end

    {Map.merge(model, %{session_id: session_id, done?: true}), []}
  end

  def update(_msg, model), do: {model, []}

  def view(_model), do: %{type: :text, content: "ok"}
end

defmodule Raxol.Symphony.TestSupport.SessionAgentEcho do
  @moduledoc """
  TEA agent that echoes the seed prompt back in a `:turn_complete`
  event (surfaced to the runner's parent as a `:run_event`) before
  `:done`. Used to prove which rendered prompt the cache served.
  """

  def init(_args), do: {%{}, []}

  def update({:agent_message, _, {:symphony_start, payload}}, model) do
    if Code.ensure_loaded?(Raxol.Agent.SessionStreamer) do
      Raxol.Agent.SessionStreamer.emit(
        payload.session_id,
        {:turn_complete, %{prompt: payload.prompt}}
      )

      Raxol.Agent.SessionStreamer.emit(payload.session_id, {:done, %{result: :ok}})
    end

    {model, []}
  end

  def update(_msg, model), do: {model, []}

  def view(_model), do: %{type: :text, content: "echo"}
end

defmodule Raxol.Symphony.TestSupport.SessionAgentErrors do
  @moduledoc """
  TEA agent module that emits a `:error` event on `:symphony_start`.
  """

  def init(_args), do: {%{}, []}

  def update({:agent_message, _, {:symphony_start, payload}}, model) do
    if Code.ensure_loaded?(Raxol.Agent.SessionStreamer) do
      Raxol.Agent.SessionStreamer.emit(payload.session_id, {:error, :backend_unavailable})
    end

    {model, []}
  end

  def update(_msg, model), do: {model, []}

  def view(_model), do: %{type: :text, content: "err"}
end

defmodule Raxol.Symphony.TestSupport.SessionAgentSilent do
  @moduledoc """
  TEA agent module that never emits anything; used to verify the
  Session-backed runner's timeout behavior.
  """

  def init(_args), do: {%{}, []}
  def update(_msg, model), do: {model, []}
  def view(_model), do: %{type: :text, content: "silent"}
end

defmodule Raxol.Symphony.TestSupport.SessionAgentPausesResumes do
  @moduledoc """
  TEA agent module that pauses on `:symphony_start` and finishes on
  `:symphony_resume`. Verifies the pause/resume contract end-to-end.
  """

  def init(_args), do: {%{}, []}

  def update({:agent_message, _, {:symphony_start, payload}}, model) do
    if Code.ensure_loaded?(Raxol.Agent.SessionStreamer) do
      Raxol.Agent.SessionStreamer.emit(
        payload.session_id,
        {:paused,
         %{
           reason: :awaiting_review,
           token: %{step: "first-half"}
         }}
      )
    end

    {Map.put(model, :session_id, payload.session_id), []}
  end

  def update({:agent_message, _, {:symphony_resume, payload}}, model) do
    if Code.ensure_loaded?(Raxol.Agent.SessionStreamer) do
      Raxol.Agent.SessionStreamer.emit(
        payload.session_id,
        {:turn_complete, %{after_resume: true}}
      )

      Raxol.Agent.SessionStreamer.emit(
        payload.session_id,
        {:done, %{resumed_with: payload.resume_value}}
      )
    end

    {model, []}
  end

  def update(_msg, model), do: {model, []}

  def view(_model), do: %{type: :text, content: "pause"}
end
