defmodule Raxol.Agent.Code.Tenant do
  @moduledoc """
  Per-tenant Code.App options for multi-tenant SSH hosting.

  One directory per tenant under the tenants root:

      <tenants_dir>/<user>/
      ├── ssh/authorized_keys   # that tenant's keys (read by the server's auth)
      ├── work/                 # the cwd jail — every fs/shell tool scopes here
      ├── code_sessions/        # the JSON session store
      └── sessions/             # the durable journal base

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
               # keyboard principal is NOT the server owner.
               jail: true,
               sessions_dir: Path.join(root, "code_sessions"),
               journal_opts: [base_dir: Path.join(root, "sessions")],
               agent_id: "ssh:" <> name
             ]}

          {:error, reason} ->
            {:error, {:tenant_workspace_failed, reason}}
        end
    end
  end
end
