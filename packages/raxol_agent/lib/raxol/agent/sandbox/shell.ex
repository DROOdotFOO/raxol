defmodule Raxol.Agent.Sandbox.Shell do
  @moduledoc """
  Shell isolation dimension for `Raxol.Agent.Sandbox`.

  Gates `Raxol.Agent.Directive.Shell` directives by matching the
  command against an allowlist, denylist, or wholesale deny.

  ## Matching semantics

  The shell command is the binary passed to
  `Raxol.Agent.Directive.shell/2`. The match check is *binary name*
  by default: `"ls -la"` matches the entry `"ls"`. For finer-grained
  matching, use a predicate function.

  ## Constructors

      Sandbox.Shell.none()
        # abstain; any shell command allowed (default-allow)

      Sandbox.Shell.deny_all()
        # block every shell command

      Sandbox.Shell.allowlist(["ls", "cat", "wc"])
        # allow only those binary names

      Sandbox.Shell.allowlist(fn cmd -> String.starts_with?(cmd, "git ") end)
        # arbitrary predicate

      Sandbox.Shell.denylist(["rm", "dd", "shutdown"])
        # block those binary names; allow everything else

      Sandbox.Shell.denylist(fn cmd -> String.contains?(cmd, "sudo") end)
        # arbitrary predicate

  The `none/0` sandbox is the default-allow case (a sandbox that
  doesn't restrict shell). The `deny_all/0` is the default-deny
  case. The other two are the explicit policies.
  """

  @typedoc """
  Internal mode. Authors use the constructors; this is the wire
  shape so the protocol impl can pattern-match.
  """
  @type mode ::
          :none
          | :deny_all
          | {:allowlist, [String.t()] | (String.t() -> boolean())}
          | {:denylist, [String.t()] | (String.t() -> boolean())}

  @type t :: %__MODULE__{mode: mode()}

  @enforce_keys [:mode]
  defstruct [:mode]

  @doc "Construct a no-op shell sandbox (abstain)."
  @spec none() :: t()
  def none, do: %__MODULE__{mode: :none}

  @doc "Construct a deny-all shell sandbox."
  @spec deny_all() :: t()
  def deny_all, do: %__MODULE__{mode: :deny_all}

  @doc """
  Construct an allowlist shell sandbox. Accepts a list of binary
  names (matched as the first whitespace-separated token of the
  command) or a 1-arity predicate function on the full command.
  """
  @spec allowlist([String.t()] | (String.t() -> boolean())) :: t()
  def allowlist(list_or_fun)
      when is_list(list_or_fun) or is_function(list_or_fun, 1),
      do: %__MODULE__{mode: {:allowlist, list_or_fun}}

  @doc """
  Construct a denylist shell sandbox. Accepts the same list or
  predicate shape as `allowlist/1`.
  """
  @spec denylist([String.t()] | (String.t() -> boolean())) :: t()
  def denylist(list_or_fun)
      when is_list(list_or_fun) or is_function(list_or_fun, 1),
      do: %__MODULE__{mode: {:denylist, list_or_fun}}

  @doc """
  Check whether `command` is permitted by the sandbox's mode.
  Exposed so callers can validate commands outside the protocol.
  """
  @spec allowed?(t(), String.t()) :: boolean()
  def allowed?(%__MODULE__{mode: :none}, _command), do: true
  def allowed?(%__MODULE__{mode: :deny_all}, _command), do: false

  def allowed?(%__MODULE__{mode: {:allowlist, list}}, command)
      when is_list(list) do
    binary_name(command) in list
  end

  def allowed?(%__MODULE__{mode: {:allowlist, fun}}, command)
      when is_function(fun, 1) do
    !!fun.(command)
  end

  def allowed?(%__MODULE__{mode: {:denylist, list}}, command)
      when is_list(list) do
    binary_name(command) not in list
  end

  def allowed?(%__MODULE__{mode: {:denylist, fun}}, command)
      when is_function(fun, 1) do
    !fun.(command)
  end

  @doc false
  def binary_name(command) when is_binary(command) do
    command
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> Kernel.||("")
  end
end

defimpl Raxol.Agent.Sandbox, for: Raxol.Agent.Sandbox.Shell do
  alias Raxol.Agent.Sandbox.Shell

  # Abstain for non-shell actions.
  def authorize(_sandbox, action, _payload, _ctx) when action != :shell, do: :ok

  def authorize(sandbox, :shell, %{command: command}, _ctx)
      when is_binary(command) do
    if Shell.allowed?(sandbox, command) do
      :ok
    else
      {:deny, {:shell_denied, sandbox.mode, command}}
    end
  end

  # If the payload is malformed, deny conservatively.
  def authorize(_sandbox, :shell, payload, _ctx),
    do: {:deny, {:shell_malformed_payload, payload}}
end
