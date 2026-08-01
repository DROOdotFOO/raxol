defmodule Raxol.ACP.Seller.Registration do
  @moduledoc """
  Idempotent seller-agent registration with the ACP Service Registry.

  Registering a seller agent (wallet id + signer, discoverable record) is done
  out-of-band today via the `acp-cli` / Virtuals dashboard. This module is the
  in-runtime seam for doing it natively. The ORCHESTRATION is implemented and
  tested here -- fail closed when the registry is unconfigured, then register
  only if not already registered (idempotent across restarts). The two pieces
  that Virtuals has not yet published are isolated behind injectable seams:

    * the Service Registry contract address -- gated by
      `Raxol.ACP.Chain.require_service_registry/1` (nil until confirmed, so this
      fails closed with `{:error, :service_registry_not_configured}`);
    * the off-chain registration call -- `Raxol.ACP.JobApi.register_agent/2`
      (the `HTTP` adapter does not implement it yet, so it returns
      `{:error, :registration_unsupported}`; `Mock` implements it for tests).

  When Virtuals confirms the registry address and the registration endpoint,
  set the address via `chain_overrides` and implement `register_agent/2` on the
  `HTTP` adapter -- this orchestration then works unchanged. An on-chain
  registration variant would slot in as `Raxol.ACP.HookClient.register_agent/_`
  (mirroring `create_job/4`); wire it as an alternative `:register` seam.

  This is NOT started at boot yet: with a nil registry address it would only
  ever fail closed, so wiring it into `Raxol.ACP.Seller.Supervisor` waits on the
  address.
  """

  alias Raxol.ACP.{Chain, JobApi}

  @type outcome ::
          {:ok, :already_registered | :registered, JobApi.agent_detail()}
          | {:error, term()}

  @doc """
  Ensure this seller agent is registered.

  Fails closed if the Service Registry address is unset. Otherwise looks the
  agent up (`JobApi.get_me/1`): if present, returns `{:ok, :already_registered,
  detail}` without re-registering; if absent (`{:error, :not_found}`), registers
  it via `JobApi.register_agent/2` and returns `{:ok, :registered, detail}`. Any
  other lookup error is surfaced as `{:error, {:lookup_failed, reason}}`.
  """
  @spec ensure_registered(Chain.config(), JobApi.t(), map()) :: outcome()
  def ensure_registered(chain, api, registration) when is_map(registration) do
    with {:ok, _address} <- Chain.require_service_registry(chain),
         :not_registered <- lookup(api) do
      case JobApi.register_agent(api, registration) do
        {:ok, detail} -> {:ok, :registered, detail}
        {:error, reason} -> {:error, {:registration_failed, reason}}
      end
    else
      {:ok, existing} -> {:ok, :already_registered, existing}
      {:error, _reason} = error -> error
    end
  end

  defp lookup(api) do
    case JobApi.get_me(api) do
      {:ok, detail} -> {:ok, detail}
      {:error, :not_found} -> :not_registered
      {:error, reason} -> {:error, {:lookup_failed, reason}}
    end
  end
end
