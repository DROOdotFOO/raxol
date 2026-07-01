defmodule Raxol.Payments.Deployment do
  @moduledoc """
  Runtime deployment detection for fund-moving defaults.

  Money-moving code fails closed in production. "Production" here means running
  as a deployed OTP release: `mix release` sets `RELEASE_NAME` in the boot
  environment and it survives into the running node, unlike `Mix.env/0`, which
  is not available at runtime in a release. Development, tests, and `mix run` do
  not set it, so their behaviour is unchanged.

  Override with `config :raxol_payments, :deployment, :production | :development`
  or the `RAXOL_PAYMENTS_DEPLOYMENT` env var (`"production"` / `"development"`) --
  primarily so tests can exercise the production path.
  """

  @doc """
  True when running as a deployed release (or forced via override).

  Fund-moving defaults (`require_policy`, `require_checkpoint`, the env-var
  wallet) key off this to fail closed in production while staying permissive in
  development and tests.
  """
  @spec production?() :: boolean()
  def production? do
    case override() do
      :production -> true
      :development -> false
      nil -> release?()
    end
  end

  defp override do
    case Application.get_env(:raxol_payments, :deployment) do
      :production -> :production
      :development -> :development
      _ -> env_override()
    end
  end

  defp env_override do
    case System.get_env("RAXOL_PAYMENTS_DEPLOYMENT") do
      "production" -> :production
      "development" -> :development
      _ -> nil
    end
  end

  defp release?, do: is_binary(System.get_env("RELEASE_NAME"))

  # -- Boot gates (call at startup in a fund-moving deployment) --

  @doc """
  True when Erlang distribution is disabled or running over TLS.

  A distributed node on the default cookie transport is reachable by any node
  that holds the cookie and can invoke any exported function or read any ETS
  table, so a signing node must run distribution over `-proto_dist inet_tls`
  (per-node certs), not a shared magic cookie.
  """
  @spec distribution_tls?() :: boolean()
  def distribution_tls?, do: not Node.alive?() or proto_dist() == "inet_tls"

  defp proto_dist do
    case :init.get_argument(:proto_dist) do
      {:ok, [[value] | _]} -> to_string(value)
      _ -> "inet_tcp"
    end
  end

  @doc false
  # Pure decision seam so the raise logic is testable without a live cluster.
  @spec insecure_distribution?(boolean(), boolean(), boolean()) :: boolean()
  def insecure_distribution?(production?, distribution_tls?, allowed?),
    do: production? and not distribution_tls? and not allowed?

  @doc """
  Raise in production when this node participates in plain (non-TLS) Erlang
  distribution. Call at boot in a fund-moving deployment so a misconfigured
  cluster halts instead of exposing the wallet over cookie-only distribution.
  Override with `RAXOL_ALLOW_INSECURE_DISTRIBUTION=true` (or
  `config :raxol_payments, :allow_insecure_distribution, true`).
  """
  @spec assert_distribution_secure!() :: :ok
  def assert_distribution_secure! do
    if insecure_distribution?(
         production?(),
         distribution_tls?(),
         insecure_distribution_allowed?()
       ) do
      raise ArgumentError,
            "Erlang distribution is running over a plain (non-TLS) transport on a " <>
              "production node. A node holding signing keys must use per-node TLS " <>
              "distribution (-proto_dist inet_tls -ssl_dist_optfile <file>). Set " <>
              "RAXOL_ALLOW_INSECURE_DISTRIBUTION=true to override."
    end

    :ok
  end

  defp insecure_distribution_allowed? do
    System.get_env("RAXOL_ALLOW_INSECURE_DISTRIBUTION") == "true" or
      Application.get_env(:raxol_payments, :allow_insecure_distribution, false) == true
  end

  @doc """
  Raise in production when a signing node also exposes the interactive REPL.

  Evaluating code on a node that holds signing keys is a capability-escape
  surface (see `Raxol.REPL.Sandbox`): keep the REPL and the wallet on separate
  nodes. A deployment that exposes the REPL sets `RAXOL_REPL_EXPOSED=true` (or
  `config :raxol_payments, :repl_exposed, true`); a signing deployment calls
  this at boot to refuse that co-location.
  """
  @spec assert_signing_isolated!() :: :ok
  def assert_signing_isolated! do
    if production?() and repl_exposed?() do
      raise ArgumentError,
            "This node holds signing keys and also exposes the interactive REPL " <>
              "(RAXOL_REPL_EXPOSED=true). Move the REPL to a node that cannot sign."
    end

    :ok
  end

  defp repl_exposed? do
    System.get_env("RAXOL_REPL_EXPOSED") == "true" or
      Application.get_env(:raxol_payments, :repl_exposed, false) == true
  end
end
