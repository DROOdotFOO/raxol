defmodule Raxol.MCP.Deployment do
  @moduledoc """
  Fail-closed environment gate for MCP authorization.

  Mirrors the posture the payments stack uses (`require_policy`): outside a
  dev/test build, a network-exposed MCP transport must not serve tools without an
  authorizer configured. stdio is exempt (it inherits the OS process boundary);
  this guards SSE.
  """

  @doc """
  True in any non-dev/test build.

  Read at RUNTIME, deliberately not captured at compile time. This module
  compiles as a dependency, and a path dependency compiles under :prod whatever
  the umbrella's environment is, so a compile-time capture answers for how
  raxol_mcp itself was built rather than for the application it protects. The two
  disagreed in exactly the case that matters: the same predicate was `false`
  under this package's own `mix test` and `true` inside a dev session of an
  application depending on it, so a dev session read as production.

  `Mix` being absent is the honest signal for a release; a dev or test session
  has it and answers for that session. Called at transport boot rather than per
  request, so reaching the loader here costs nothing.

  Note this is no longer a compile-time constant, which the previous shape
  hoisted to a module attribute to avoid: inlined, `@mix_env not in [:dev, :test]`
  compared two atoms the type checker knew were disjoint and warned on every
  build. `Mix.env/0` is opaque to it, so the comparison is now an ordinary one.
  """
  @spec production?() :: boolean()
  def production? do
    if Code.ensure_loaded?(Mix), do: Mix.env() not in [:dev, :test], else: true
  end

  @doc """
  Whether a network transport must refuse to expose tools without an authorizer.

  Defaults to `production?/0`; override with
  `config :raxol_mcp, require_authorization: boolean`.
  """
  @spec require_authorization?() :: boolean()
  def require_authorization? do
    Application.get_env(:raxol_mcp, :require_authorization, production?())
  end

  @doc """
  Fail-closed boot check. Raises when authorization is required in this
  environment but the fronted server has no authorizer configured; a no-op
  otherwise. `context` names the caller for the error message.
  """
  @spec enforce_authorization!(boolean(), String.t()) :: :ok
  def enforce_authorization!(authorizer_configured?, context \\ "MCP transport")

  def enforce_authorization!(true, _context), do: :ok

  def enforce_authorization!(false, context) do
    if require_authorization?() do
      raise ArgumentError,
            "#{context} refuses to boot: authorization is required in this environment " <>
              "but no authorizer is configured on the MCP server. Configure an :authorizer " <>
              "on Raxol.MCP.Server, or override with " <>
              "`config :raxol_mcp, require_authorization: false`."
    else
      :ok
    end
  end
end
