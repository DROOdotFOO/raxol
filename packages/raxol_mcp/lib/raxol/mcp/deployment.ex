defmodule Raxol.MCP.Deployment do
  @moduledoc """
  Fail-closed environment gate for MCP authorization.

  Mirrors the posture the payments stack uses (`require_policy`): outside a
  dev/test build, a network-exposed MCP transport must not serve tools without an
  authorizer configured. stdio is exempt (it inherits the OS process boundary);
  this guards SSE.
  """

  # Captured at compile time: `Mix` is absent in a release, and a path-dep
  # package compiles under :prod regardless of the umbrella's env, so fall back
  # to :prod when Mix is gone rather than crash or read the wrong env.
  @mix_env if Code.ensure_loaded?(Mix), do: Mix.env(), else: :prod

  # Resolved here rather than in the function body. Inlined into `production?/0`
  # the membership test compares two atoms the type checker already knows are
  # disjoint, which it reports as a typing violation on every build.
  @production? @mix_env not in [:dev, :test]

  @doc "True in any non-dev/test build."
  @spec production?() :: boolean()
  def production?, do: @production?

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
