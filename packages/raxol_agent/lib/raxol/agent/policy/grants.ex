defmodule Raxol.Agent.Policy.Grants do
  @moduledoc """
  What a tool context is granted: the shell gate (jail rule, then the
  configured `Raxol.Agent.Sandbox.Shell` policy), the network gate, and the
  one definition of a jailed (multi-tenant) session they both read.

  Every surface that runs a shell string or reaches the network asks here, so
  they cannot disagree about what a context permits.
  """

  alias Raxol.Agent.Sandbox.Shell

  @doc """
  The single gate every shell surface passes through: the jail rule, then the
  configured `Raxol.Agent.Sandbox.Shell` policy.

  Use this rather than calling `shell_jail_allow/1` and `sandbox_allow/2`
  separately. Four places run a shell string, and when each applied its own
  subset they disagreed about what was permitted. What each does now:

    * `Raxol.Agent.Actions.Code.Bash` -- calls this.
    * `Raxol.Agent.Actions.Shell` -- calls this. It applied nothing at all.
    * `Raxol.Agent.Code.Hooks` -- the jail half only, via `jailed?/1`. Hooks
      are refused wholesale in a jail, so the sandbox half has nothing left
      to decide.
    * the `Directive.Shell` executor -- calls this, but binds on the
      DISPATCHER context, which does not carry `:jail` or `:shell_sandbox`.
      So it is a real gate for a surface that scopes that context and a
      pass-through for the ones in this repo. Confining that path in a jail
      needs those keys plumbed through the runtime, which is not done yet;
      `Raxol.Agent.SandboxHook` is the only thing standing in front of it,
      and it is opt-in on the agent's own `sandbox/0`.
  """
  @spec shell_allow(map(), String.t()) :: :ok | {:error, term()}
  def shell_allow(context, command) do
    with :ok <- shell_jail_allow(context), do: sandbox_allow(context, command)
  end

  @doc """
  Refuse the shell surface for a jailed (multi-tenant) session.

  The cwd jail confines the *fs* tools (they resolve every path through
  `Fs.resolve/2`), but a `/bin/sh -c` command string is not a path — it can
  `cd ..`, name an absolute path, or read the daemon's own files, none of
  which `{:cd, cwd}` prevents. On a shared host that is a cross-tenant read
  and write primitive.

  A jail has NO unlock here. It used to accept any `%Sandbox.Shell{}` in the
  context as evidence of confinement, but that struct is a string matcher:
  `Sandbox.Shell.none()` satisfied the check and restored an unrestricted
  shell, and even an allowlist only ever inspected the first token. What
  would justify re-enabling this is OS-level confinement -- a separate uid,
  a chroot, a container -- which does not exist here yet. When it does, it
  gets its own explicit seam rather than reusing a lexical policy's struct
  as a flag.
  """
  @spec shell_jail_allow(map()) :: :ok | {:error, :shell_disabled_in_jail}
  def shell_jail_allow(context) do
    if jailed?(context), do: {:error, :shell_disabled_in_jail}, else: :ok
  end

  @doc """
  Whether `context` may reach the network (`fetch`, `web_search`).

  Default-on, and off by default in a jail. `fetch` and `web_search` joined
  the DEFAULT toolset, which changes what a hosted multi-tenant session is:
  every tenant gets outbound HTTP from the operator's address and spends the
  operator's search quota, on a surface whose whole premise is that tenants do
  not share. A path sandbox does not bear on that either way, which is why
  this is its own gate rather than a second reading of `jailed?/1` -- but a
  jail is the marker this codebase has for "this session is somebody else's",
  so it is the right default.

  `network: true` in the context re-enables it for a deployment that means to
  offer it, and `network: false` disables it anywhere.
  """
  @spec network_allow(map()) :: :ok | {:error, :network_disabled}
  def network_allow(context) do
    case is_map(context) and Map.get(context, :network) do
      true -> :ok
      false -> {:error, :network_disabled}
      _unset -> if jailed?(context), do: {:error, :network_disabled}, else: :ok
    end
  end

  @doc """
  Whether `context` marks a jailed (multi-tenant) session.

  The one definition of what a jail is. `Raxol.Agent.Code.Hooks` used to carry
  a copy of this test with a comment saying it mirrored this one, which is the
  arrangement that lets two answers drift apart.
  """
  @spec jailed?(map()) :: boolean()
  def jailed?(context),
    do: is_map(context) and Map.get(context, :jail) not in [nil, false]

  @doc """
  Check a shell command against a `Raxol.Agent.Sandbox.Shell` in the
  context under `:shell_sandbox`. Absent → allowed.
  """
  @spec sandbox_allow(map(), String.t()) :: :ok | {:error, term()}
  def sandbox_allow(context, command) do
    case Map.get(context, :shell_sandbox) do
      %Shell{} = sandbox ->
        if Shell.allowed?(sandbox, command),
          do: :ok,
          else: {:error, {:shell_denied, command}}

      _ ->
        :ok
    end
  end
end
