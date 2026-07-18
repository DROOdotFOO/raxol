defmodule Raxol.Symphony.OrchestratorClient do
  @moduledoc """
  Shared orchestrator-command helpers for the Symphony surfaces.

  Centralizes the fault-tolerant `safe_call/1` wrapper and the three
  orchestrator command mappings (`refresh/1`, `stop/2`, `resume/3`) that the
  Web, Telegram, and Watch surfaces each dispatched identically. The Web API,
  LiveView dashboard, MCP, and Terminal surfaces reuse `safe_call/1` directly.
  """

  alias Raxol.Symphony.Orchestrator

  @doc """
  Invokes `fun`, returning `{:ok, fun.()}`. Catches an `:exit` (e.g. a call to
  a down orchestrator) or a raised `:error` from the wrapped call and returns
  `:error`. Thrown values are deliberately not caught.
  """
  @spec safe_call((-> result)) :: {:ok, result} | :error when result: var
  def safe_call(fun) do
    {:ok, fun.()}
  catch
    :exit, _ -> :error
    :error, _ -> :error
  end

  @doc "Requests an orchestrator tick. Always reports `{:ok, :refresh}`."
  @spec refresh(GenServer.server()) :: {:ok, :refresh}
  def refresh(orch) do
    _ = safe_call(fn -> Orchestrator.refresh(orch) end)
    {:ok, :refresh}
  end

  @doc """
  Stops a run by issue id. Maps `Orchestrator.stop_run/2` to `{:ok, :stopped}`,
  `{:error, reason}`, or `{:error, :orchestrator_unavailable}` on a failed call.
  """
  @spec stop(GenServer.server(), binary()) :: {:ok, :stopped} | {:error, atom()}
  def stop(orch, id) do
    case safe_call(fn -> Orchestrator.stop_run(orch, id) end) do
      {:ok, :ok} -> {:ok, :stopped}
      {:ok, {:error, reason}} -> {:error, reason}
      _ -> {:error, :orchestrator_unavailable}
    end
  end

  @doc """
  Resumes a paused run. Maps `Orchestrator.resume_run/3` to
  `{:ok, {:resumed, decision}}`, `{:error, reason}`, or
  `{:error, :orchestrator_unavailable}` on a failed call.
  """
  @spec resume(GenServer.server(), binary(), term()) ::
          {:ok, {:resumed, term()}} | {:error, atom()}
  def resume(orch, id, decision) do
    case safe_call(fn -> Orchestrator.resume_run(orch, id, decision) end) do
      {:ok, :ok} -> {:ok, {:resumed, decision}}
      {:ok, {:error, reason}} -> {:error, reason}
      _ -> {:error, :orchestrator_unavailable}
    end
  end
end
