defmodule Raxol.Symphony.AgentMetadata do
  @moduledoc """
  Reads runtime metadata declared on a `use Raxol.Agent` module and
  surfaces it to the Symphony `RaxolAgent` runner.

  When `agent.module: MyApp.MyAgent` is set in the runner config the
  runner consults this module to pick up:

    * `Raxol.Agent.effective_hooks(module)` -- the CommandHook chain
      with `Raxol.Agent.SandboxHook` prepended if the agent declares
      a non-empty `sandbox/0`. Exposed for inspection and for
      Session-backed extensions; the Stream-based runner does not
      execute hooks itself.
    * `module.sandbox()` -- list of `Raxol.Agent.Sandbox` impls. The
      runner prepends these to the per-turn Sandbox chain so the
      agent's authorization policy is consulted alongside Symphony's
      own.
    * `Raxol.Agent.thread_log_adapter(module)` -- the agent's
      `Raxol.Agent.ThreadLog` adapter. The runner uses this when the
      config does not specify `agent.thread_log` directly.

  ## Resolution precedence

  Per-config-key values win over module-declared values:

      agent.thread_log    > module.thread_log/0
      agent.sandboxes ++ module.sandbox/0    (concatenated, module last)

  Symphony's sandbox chain is always evaluated first-to-last; putting
  the module's sandboxes last preserves the principle that
  per-instance config overrides declared defaults.

  ## Optional dep

  `raxol_agent` is an optional dep of `raxol_symphony`. When it is not
  loaded, this module returns sensible empty defaults so the runner
  still functions.
  """

  @compile {:no_warn_undefined, [Raxol.Agent]}

  @type t :: %{
          module: module() | nil,
          hooks: [module()],
          sandboxes: [term()],
          thread_log: {module(), map()} | nil
        }

  @doc """
  Read metadata from `module` (or `nil` for none). Safe to call when
  `raxol_agent` is not loaded; returns the empty-defaults map.
  """
  @spec read(module() | nil) :: t()
  def read(nil), do: empty(nil)

  def read(module) when is_atom(module) do
    Code.ensure_loaded(module)

    if Code.ensure_loaded?(Raxol.Agent) do
      %{
        module: module,
        hooks: Raxol.Agent.effective_hooks(module),
        sandboxes: safe_call(module, :sandbox, [], []),
        thread_log: Raxol.Agent.thread_log_adapter(module)
      }
    else
      empty(module)
    end
  end

  defp empty(module),
    do: %{module: module, hooks: [], sandboxes: [], thread_log: nil}

  defp safe_call(module, fun, args, default) do
    if function_exported?(module, fun, length(args)) do
      apply(module, fun, args)
    else
      default
    end
  end
end
