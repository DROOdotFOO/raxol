defmodule Raxol.Agent.OMP.Principal do
  @moduledoc """
  The authenticated person an OMP session answers to (ADR-0042, decision 7).

  An OMP session runs tools on this host, so `Raxol.Agent.OMP.Lane` refuses
  to start without a principal and sends it every exec-tier approval.
  `authenticate/1` turns a surface's claim into a principal only where the
  surface authenticated one person:

    * `{:gateway, pairing, route, pid}`: a `Raxol.Gateway.Route` whose user
      `pairing` (a `Raxol.Gateway.Pairing` server) grants on that route's
      platform (`Raxol.Gateway.Pairing.platform_granted?/2`). This is how
      Telegram fronts OMP: `Raxol.Telegram.GatewayAdapter` builds the route
      from the sender's `from.id`. A DM pairing, the global allowlist and an
      allow-everyone platform are not grants on one platform, so they do not
      count, and neither does a route with no user id.
    * `{:ssh, server, connection, pid}`: a connection to a `Raxol.SSH.Server`
      running with `:tenants_dir`, whose key bound the username
      (`Raxol.SSH.Server.tenant/2`). A served app finds `{server, connection}`
      in its `:ssh_connection` option.

  Nothing else is a principal. `Raxol.Telegram.Bot`'s `allowed_chat_ids`
  names chats, not people (nil admits every chat and a group admits every
  member), a single-tenant SSH server lets any keyholder claim any
  username, and LiveView has no authentication.

  `pid` is the process that answers approvals for that person
  (`Raxol.Agent.OMP.RPC.answer/3`). A surface must route only that
  person's messages to the session.

  Refusals are `{:unauthenticated_principal, reason}`: `:no_user_id`,
  `:not_granted`, `:pairing_unavailable` (no `raxol_gateway`, or the
  Pairing server is not running), `:no_tenants_dir`, `:foreign_connection`,
  `:no_authenticated_user`, `:ssh_server_down` and `:unsupported` (any
  other claim).
  """

  @compile {:no_warn_undefined, [Raxol.Gateway.Pairing]}

  @enforce_keys [:surface, :id, :pid]
  defstruct [:surface, :id, :pid]

  @type t :: %__MODULE__{
          surface: {:gateway, atom()} | :ssh,
          id: String.t(),
          pid: pid()
        }

  @doc "Authenticate a surface's claim; see the moduledoc."
  @spec authenticate(term()) :: {:ok, t()} | {:error, {:unauthenticated_principal, atom()}}
  def authenticate({:gateway, pairing, %{platform: platform, user_id: user_id} = route, pid})
      when is_struct(route, Raxol.Gateway.Route) and is_atom(platform) and is_pid(pid) do
    with {:ok, id} <- user_id(user_id),
         :ok <- platform_grant(pairing, route) do
      {:ok, %__MODULE__{surface: {:gateway, platform}, id: id, pid: pid}}
    end
  end

  def authenticate({:ssh, server, connection, pid}) when is_pid(pid) do
    case Raxol.SSH.Server.tenant(server, connection) do
      {:ok, tenant} -> {:ok, %__MODULE__{surface: :ssh, id: tenant, pid: pid}}
      {:error, reason} -> refuse(reason)
    end
  end

  def authenticate(_claim), do: refuse(:unsupported)

  defp user_id(id) when is_integer(id), do: {:ok, Integer.to_string(id)}
  defp user_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp user_id(_id), do: refuse(:no_user_id)

  defp platform_grant(pairing, route) do
    cond do
      not Code.ensure_loaded?(Raxol.Gateway.Pairing) -> refuse(:pairing_unavailable)
      Raxol.Gateway.Pairing.platform_granted?(pairing, route) -> :ok
      true -> refuse(:not_granted)
    end
  catch
    :exit, _reason -> refuse(:pairing_unavailable)
  end

  defp refuse(reason), do: {:error, {:unauthenticated_principal, reason}}
end
