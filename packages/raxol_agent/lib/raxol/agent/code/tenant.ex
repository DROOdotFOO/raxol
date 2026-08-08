defmodule Raxol.Agent.Code.Tenant do
  @moduledoc """
  Per-tenant Code.App options for multi-tenant SSH hosting.

  One directory per tenant under the tenants root:

      <tenants_dir>/<user>/
      ├── ssh/authorized_keys   # that tenant's keys (read by the server's auth)
      ├── work/                 # the cwd jail — the fs tools scope here
      ├── code_sessions/        # the JSON session store
      └── sessions/             # the durable journal base

  The `work/` jail confines the *fs* tools (read/write/edit/list/grep/glob,
  all of which resolve paths through `Raxol.Agent.Actions.Fs.resolve/2`). It
  does NOT confine the shell: a `/bin/sh -c` command line can `cd` or name an
  absolute path, and `{:cd, work}` is a starting directory, not a boundary.
  So `jail: true` disables the shell tool entirely (see
  `Raxol.Agent.Actions.Code.shell_jail_allow/1`) until per-tenant OS
  confinement is wired. Real cross-tenant isolation still wants separate OS
  uids or containers; this is one BEAM, one uid.

  `app_opts/2` is the `:tenant_opts` fun the SSH server calls with the
  AUTHENTICATED username; it applies the same username normalization the
  key lookup used (`Raxol.SSH.Server.sanitize_tenant/1`), so the identity
  that authenticated and the workspace that opens can never diverge. The
  spending identity is `"ssh:<user>"` — with a host-wired ledger/policy
  (server-level app_opts), each tenant draws on their own budget.
  """

  @doc """
  Derive the per-tenant app options for `user`, creating the tenant's
  workspace directories as needed. `{:error, reason}` refuses the
  session (the server fails closed on it).
  """
  @spec app_opts(String.t(), String.t()) ::
          {:ok, keyword()} | {:error, term()}
  def app_opts(tenants_dir, user) do
    case Raxol.SSH.Server.sanitize_tenant(user) do
      nil ->
        {:error, :invalid_tenant}

      name ->
        root = Path.join(Path.expand(tenants_dir), name)
        work = Path.join(root, "work")

        case File.mkdir_p(work) do
          :ok ->
            {:ok,
             [
               cwd: work,
               # The jail flag makes operator-typed escapes (/export to an
               # absolute path) refuse too: on a multi-tenant host the
               # keyboard principal is NOT the server owner. It also stops
               # this session loading `.raxol/hooks.json` or `.mcp.json` out
               # of the tenant-writable workspace, both of which name a
               # command to run outside the jail.
               jail: true,
               sessions_dir: Path.join(root, "code_sessions"),
               journal_opts: [base_dir: Path.join(root, "sessions")],
               agent_id: "ssh:" <> name,
               # `/share` signs this into the token, so the viewer resolves
               # THIS tenant's journal base. Session ids are unique per base,
               # not per host, so an unscoped token would name a session
               # ambiguously across tenants.
               share_scope: name
             ]}

          {:error, reason} ->
            {:error, {:tenant_workspace_failed, reason}}
        end
    end
  end
end
