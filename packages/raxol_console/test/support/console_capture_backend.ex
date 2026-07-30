defmodule Raxol.Console.Test.CaptureBackend do
  @moduledoc """
  A real `Raxol.Agent.AIBackend` that records the messages it is asked to
  complete and returns a canned response. Lets the scheduler-wiring test prove
  the persona reaches the model on a scheduled fire, with only the LLM faked at
  the external boundary.
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
