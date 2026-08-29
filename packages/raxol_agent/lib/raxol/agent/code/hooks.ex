defmodule Raxol.Agent.Code.Hooks do
  @moduledoc """
  Settings-file lifecycle hooks for `mix raxol.code`.

  A `.raxol/hooks.json` in the working directory declares shell commands to
  run around the tool loop:

      {
        "pre_tool_use":  [{"match": "bash", "command": "./scripts/guard.sh"}],
        "post_tool_use": [{"match": "*", "command": "mix format"}],
        "stop":          ["mix test --stale"]
      }

  * **pre_tool_use** — runs before a matching tool. A non-zero exit **vetoes**
    the tool call (the loop is told the tool was refused), so a guard script
    can block a dangerous command. Runs on the `ToolCall.Hook` `before_call`
    seam.
  * **post_tool_use** — runs after a matching tool; its exit status is
    ignored and it cannot change the result (`after_call`).
  * **stop** — runs once when a turn finishes (driven by the surface).

  `match` is an exact tool name or `"*"` (any). The matched command runs via
  `/bin/sh -c` in the working directory with `RAXOL_TOOL_NAME` set. Config
  travels in the run context under `:code_hooks`, so this one module serves
  every session without per-config module generation.

  ## Never in a jail

  A hook is workspace-configured code execution: the command string reaches
  `/bin/sh -c` with no approval prompt, no allowlist, and no cwd confinement
  (a command line can `cd` anywhere). That is fine when the keyboard
  principal owns the host — they could run the same command in their own
  shell. It is NOT fine on a multi-tenant host, where `.raxol/hooks.json`
  sits inside a tenant's writable jail and the agent's own `write_file` can
  author it: running it would hand every tenant arbitrary execution as the
  server uid, defeating the cwd jail and the `:jail` shell gate in one step.

  So hooks are refused whenever the tool context carries `jail: true` — the
  same marker `Raxol.Agent.Actions.Code.shell_jail_allow/1` gates the shell
  tool on. `Raxol.Agent.Code.App` additionally declines to LOAD the config in
  a jailed session, so this check is the second of two independent gates.
  """

  @behaviour Raxol.Agent.ToolCall.Hook

  alias Raxol.Agent.Actions.Code

  @hook_timeout_ms 30_000

  @type rule :: %{match: String.t(), command: String.t()}
  @type config :: %{pre: [rule()], post: [rule()], stop: [String.t()]}

  # -- loading ----------------------------------------------------------------

  @doc """
  Load hooks from `<dir>/.raxol/hooks.json`.

  Returns `{:ok, config}`, `:none` when there is no file, or `{:error,
  reason}` for an unreadable/invalid file (never silently ignored).
  """
  @spec load(String.t()) :: {:ok, config()} | :none | {:error, term()}
  def load(dir) do
    path = Path.join(dir, ".raxol/hooks.json")

    case File.read(path) do
      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, {:read_failed, reason}}

      {:ok, binary} ->
        case Jason.decode(binary) do
          {:ok, json} when is_map(json) -> {:ok, parse(json)}
          {:ok, _other} -> {:error, :not_an_object}
          {:error, _} -> {:error, :invalid_json}
        end
    end
  end

  @doc "Total number of declared hooks in a config."
  @spec count(config() | nil) :: non_neg_integer()
  def count(%{pre: pre, post: post, stop: stop}),
    do: length(pre) + length(post) + length(stop)

  def count(_other), do: 0

  defp parse(json) do
    %{
      pre: parse_rules(Map.get(json, "pre_tool_use", [])),
      post: parse_rules(Map.get(json, "post_tool_use", [])),
      stop: parse_commands(Map.get(json, "stop", []))
    }
  end

  defp parse_rules(list) when is_list(list),
    do: list |> Enum.map(&parse_rule/1) |> Enum.reject(&is_nil/1)

  defp parse_rules(_other), do: []

  defp parse_rule(%{"command" => command} = rule) when is_binary(command),
    do: %{match: Map.get(rule, "match", "*"), command: command}

  defp parse_rule(_other), do: nil

  defp parse_commands(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{"command" => c} when is_binary(c) -> [c]
      c when is_binary(c) -> [c]
      _other -> []
    end)
  end

  defp parse_commands(_other), do: []

  # -- ToolCall.Hook callbacks ------------------------------------------------

  @impl true
  def before_call(call, context) do
    case run_pre(rules(context, :pre), call.name, cwd(context)) do
      :ok ->
        {:cont, call}

      {:blocked, command, status} ->
        {:halt, {:hook_blocked, call.name, command, status}}
    end
  end

  @impl true
  def after_call(call, result, context) do
    run_post(rules(context, :post), call.name, cwd(context))
    result
  end

  @doc """
  Run a config's `stop` commands in `cwd`, returning a receipt per command.
  Driven by the surface at turn end (not part of the tool-call pipeline).
  """
  @spec run_stop(config(), String.t()) :: [
          %{command: String.t(), exit_status: integer() | :timeout}
        ]
  def run_stop(%{stop: commands}, cwd) do
    Enum.map(commands, fn command ->
      {_out, status} = Code.run_shell(command, cwd, @hook_timeout_ms, env(nil))
      %{command: command, exit_status: status}
    end)
  end

  # -- running ----------------------------------------------------------------

  # First matching pre-hook with a non-zero exit vetoes the call.
  defp run_pre(rules, tool_name, cwd) do
    rules
    |> Enum.filter(&matches?(&1.match, tool_name))
    |> Enum.reduce_while(:ok, fn rule, :ok ->
      {_out, status} = Code.run_shell(rule.command, cwd, @hook_timeout_ms, env(tool_name))

      if status == 0,
        do: {:cont, :ok},
        else: {:halt, {:blocked, rule.command, status}}
    end)
  end

  # Post-hooks all run; their status is advisory only.
  defp run_post(rules, tool_name, cwd) do
    rules
    |> Enum.filter(&matches?(&1.match, tool_name))
    |> Enum.each(fn rule ->
      Code.run_shell(rule.command, cwd, @hook_timeout_ms, env(tool_name))
    end)
  end

  defp matches?("*", _tool_name), do: true
  defp matches?(pattern, tool_name), do: pattern == tool_name

  # A jailed session has no hooks, whatever its workspace config says: the
  # keyboard principal is a tenant, not the server owner, and a hook command
  # is unconfined execution. Fail closed here as well as at load time.
  defp rules(context, key) do
    if jailed?(context) do
      []
    else
      case Map.get(context, :code_hooks) do
        %{} = config -> Map.get(config, key, [])
        _other -> []
      end
    end
  end

  @doc """
  Whether `context` marks a jailed (multi-tenant) session, in which hooks
  never run. Delegates to `Raxol.Agent.Actions.Code.jailed?/1` so the shell
  tools and the hook path cannot disagree about what a jail is.
  """
  @spec jailed?(map()) :: boolean()
  defdelegate jailed?(context), to: Code

  defp cwd(context), do: Map.get(context, :hook_cwd) || File.cwd!()

  defp env(nil), do: []
  defp env(tool_name), do: [{"RAXOL_TOOL_NAME", tool_name}]
end
