defmodule Raxol.Symphony.TestSupport.AgentWithMetadata do
  @moduledoc """
  Test agent module that declares the optional metadata callbacks
  the Symphony runner reads via `Raxol.Symphony.AgentMetadata`:

    * `sandbox/0` -- a list of `Raxol.Agent.Sandbox` impls.
    * `thread_log/0` -- a `Raxol.Agent.ThreadLog` adapter tuple.
    * `command_hooks/0` -- inert here; included so
      `effective_hooks/1` returns a non-empty chain.
  """

  def sandbox do
    [%Raxol.Symphony.TestSupport.DenyTurnSandbox{reason: :module_deny}]
  end

  def thread_log do
    {Raxol.Agent.ThreadLog.Ets, %{table: :symphony_test_module_thread_log}}
  end

  def command_hooks do
    [Raxol.Symphony.TestSupport.NoopHook]
  end
end

defmodule Raxol.Symphony.TestSupport.NoopHook do
  @moduledoc false
  def pre_execute(directive, _ctx), do: {:ok, directive}
  def post_execute(_directive, result, _ctx), do: result
end

defmodule Raxol.Symphony.TestSupport.AgentWithoutMetadata do
  @moduledoc "Agent module that declares NO optional metadata callbacks."
end
