defmodule Raxol.Console.Test.CaptureBackend do
  @moduledoc """
  A real `Raxol.Agent.AIBackend` that records the messages it is asked to
  complete and returns a canned response. Used by the Stage-3 prototype to prove
  the soul.md persona actually reaches the model on a scheduled fire -- the
  external LLM boundary is the only part faked; `Scheduler`, `Fire`, `Stream`,
  `Delivery`, and the gateway adapter are all real.

  Options (via `backend_opts`):

    * `:sink`     -- pid the completed `messages` list is sent to as
      `{:backend_messages, messages}` (default: none).
    * `:response` -- the assistant content to return (default: `"ok"`).
    * `:error`    -- when set, return `{:error, reason}` instead (for the
      delivery-failure path).
  """

  @behaviour Raxol.Agent.AIBackend

  @impl true
  def complete(messages, opts \\ []) do
    case Keyword.get(opts, :sink) do
      pid when is_pid(pid) -> send(pid, {:backend_messages, messages})
      _ -> :ok
    end

    case Keyword.get(opts, :error) do
      nil ->
        {:ok,
         %{
           content: Keyword.get(opts, :response, "ok"),
           usage: %{input_tokens: 0, output_tokens: 0},
           metadata: %{backend: :capture, model: "capture-1"}
         }}

      reason ->
        {:error, reason}
    end
  end

  @impl true
  def stream(messages, opts \\ []) do
    case complete(messages, opts) do
      {:ok, response} -> {:ok, [{:chunk, response.content}, {:done, response}]}
      error -> error
    end
  end

  @impl true
  def available?, do: true

  @impl true
  def name, do: "Capture Backend"

  @impl true
  def capabilities, do: [:completion, :streaming]

  @impl true
  def handles_tools_internally?, do: false

  @impl true
  def max_context_tokens, do: nil
end
