defmodule Raxol.Agent.PermissionHook do
  @moduledoc """
  Runtime permission enforcement for agent commands.

  Implements `CommandHook` to check commands against a permission policy
  before execution. Supports a hierarchical permission mode with per-command-type
  requirements and an optional prompter for interactive escalation.

  ## Permission Modes (ordered least to most permissive)

  - `:read_only` -- no side effects allowed
  - `:send_only` -- inter-agent messaging only
  - `:workspace_write` -- file writes within workspace
  - `:full_access` -- shell, system, network
  - `:allow` -- everything permitted

  ## Usage

      # Create a policy
      policy = PermissionHook.policy(:workspace_write)

      # Use as a command hook
      defmodule MyAgent do
        use Raxol.Agent

        def command_hooks do
          [PermissionHook.new(:workspace_write)]
        end
      end

  ## Custom Prompter

  For interactive permission escalation (terminal prompt, SSH, LiveView):

      policy = PermissionHook.policy(:read_only,
        prompter: fn command, _context ->
          # Ask user for permission
          IO.gets("Allow \#{command.type}? [y/n] ") |> String.trim() == "y"
        end
      )
  """

  @behaviour Raxol.Agent.CommandHook

  alias Raxol.Agent.Directive
  alias Raxol.Core.Runtime.Command

  @type mode ::
          :read_only
          | :send_only
          | :workspace_write
          | :full_access
          | :allow

  @type effect :: Command.t() | Directive.t()
  @type prompter :: (effect(), map() -> boolean())

  @type t :: %__MODULE__{
          mode: mode(),
          prompter: prompter() | nil,
          denied_types: MapSet.t(atom())
        }

  defstruct [:mode, :prompter, denied_types: MapSet.new()]

  @mode_order [:read_only, :send_only, :workspace_write, :full_access, :allow]
  @mode_ranks @mode_order |> Enum.with_index() |> Map.new()

  @command_requirements %{
    none: :read_only,
    delay: :read_only,
    broadcast: :read_only,
    clipboard_read: :read_only,
    send_agent: :send_only,
    task: :send_only,
    async: :send_only,
    clipboard_write: :workspace_write,
    notify: :workspace_write,
    system: :full_access,
    shell: :full_access,
    quit: :read_only
  }

  @doc """
  Set the active permission policy for the current process.

  Returns the module name for use in `command_hooks/0` lists.
  The policy is stored in the process dictionary, so each agent
  process maintains its own independent policy.
  """
  @spec new(mode(), keyword()) :: module()
  def new(mode, opts \\ []) do
    set_policy(policy(mode, opts))
    __MODULE__
  end

  @doc """
  Set the active policy for the current process.
  """
  @spec set_policy(t()) :: :ok
  def set_policy(%__MODULE__{} = policy) do
    Process.put({__MODULE__, :policy}, policy)
    :ok
  end

  @doc """
  Create a permission policy struct.
  """
  @spec policy(mode(), keyword()) :: t()
  def policy(mode, opts \\ []) when mode in @mode_order do
    %__MODULE__{
      mode: mode,
      prompter: Keyword.get(opts, :prompter),
      denied_types: build_denied_types(mode)
    }
  end

  @doc """
  Check whether a command is authorized under the given policy.
  """
  @spec authorize(effect(), t(), map()) :: :allow | {:deny, String.t()}
  def authorize(%Command{type: type}, %__MODULE__{} = policy, context) do
    check_type(type, policy, context)
  end

  def authorize(directive, %__MODULE__{} = policy, context) when is_struct(directive) do
    check_type(effect_type(directive), policy, context)
  end

  defp check_type(type, %__MODULE__{} = policy, context) do
    if MapSet.member?(policy.denied_types, type) do
      maybe_prompt(type, policy, context)
    else
      :allow
    end
  end

  defp effect_type(%Directive.Async{}), do: :async
  defp effect_type(%Directive.Shell{}), do: :shell
  defp effect_type(%Directive.SendAgent{}), do: :send_agent
  defp effect_type(%Directive.Schedule{}), do: :delay
  defp effect_type(%Directive.Spawn{}), do: :task
  defp effect_type(%Directive.Stop{}), do: :quit

  @doc """
  Returns the minimum permission mode required for a command type.
  """
  @spec required_mode(atom()) :: mode()
  def required_mode(command_type) do
    Map.get(@command_requirements, command_type, :full_access)
  end

  @doc """
  Check if mode `a` is at least as permissive as mode `b`.
  """
  @spec mode_permits?(mode(), mode()) :: boolean()
  def mode_permits?(active, required) do
    mode_rank(active) >= mode_rank(required)
  end

  # -- CommandHook callbacks ---------------------------------------------------

  @impl Raxol.Agent.CommandHook
  def pre_execute(command, context) do
    policy = get_active_policy()

    case authorize(command, policy, context) do
      :allow -> {:ok, command}
      {:deny, reason} -> {:deny, reason}
    end
  end

  # -- Private -----------------------------------------------------------------

  defp get_active_policy do
    Process.get({__MODULE__, :policy}) || policy(:allow)
  end

  defp build_denied_types(mode) do
    active_rank = mode_rank(mode)

    @command_requirements
    |> Enum.filter(fn {_type, required} ->
      mode_rank(required) > active_rank
    end)
    |> Enum.map(fn {type, _} -> type end)
    |> MapSet.new()
  end

  defp mode_rank(mode), do: Map.get(@mode_ranks, mode, 0)

  defp maybe_prompt(type, %{prompter: nil, mode: mode}, _context) do
    required = required_mode(type)

    {:deny,
     "Command :#{type} requires :#{required} mode, " <>
       "but agent is running in :#{mode} mode"}
  end

  defp maybe_prompt(type, %{prompter: prompter}, context)
       when is_function(prompter, 2) do
    command = %Command{type: type, data: nil}

    if prompter.(command, context) do
      :allow
    else
      {:deny, "Permission denied by prompter for :#{type}"}
    end
  end
end
