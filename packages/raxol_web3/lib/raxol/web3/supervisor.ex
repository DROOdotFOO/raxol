defmodule Raxol.Web3.Supervisor do
  @moduledoc """
  The package's supervision tree, and its application callback.

  One child: `Raxol.Web3.Tables`, which owns the rate-limit, circuit-breaker
  and origin-id tables. Starting automatically is the point. A consumer that
  adds this package as a dependency gets the tables, so nothing in the outbound
  path has to decide whether a limiter exists, and a bucket cannot silently
  degrade to per-process because some caller forgot to start the owner.

  `:one_for_one` with the default permanent restart: if the table owner ever
  goes down it must come back, because everything below it fails closed
  (`Raxol.Core.TokenBucket` refuses when it cannot commit, and a missing table
  raises rather than admitting).

  ## The boot-time client assertion

  `start/2` also asserts that `Raxol.MCP.BoundedExchange` is loadable, for the
  same reason `mix.exs` lists `:ssl` in `:extra_applications`: a missing piece
  of the outbound path should stop the boot, not the first request. The bounded
  read lives in `raxol_mcp`, where `mint` is an OPTIONAL dependency, while here
  `mint` is required and opening TLS connections is the whole purpose of the
  package. So a `raxol_mcp` compiled in a build without `mint`, or a stale
  `_build` that kept some of the guarded modules and dropped others, leaves
  this package with a guarded client that raises `UndefinedFunctionError` on
  its first outbound request, which is both the latest and the least
  informative moment to find out.
  """

  use Application

  @bounded_exchange Raxol.MCP.BoundedExchange

  @impl Application
  def start(_type, _args) do
    :ok = assert_client!()

    Supervisor.start_link([Raxol.Web3.Tables], strategy: :one_for_one, name: __MODULE__)
  end

  @doc """
  Raise unless the bounded read this package dials through is loadable.

  Takes the module so the refusal itself is testable; the missing-build state
  it reports cannot be produced from inside a build that has the module.
  """
  @spec assert_client!(module()) :: :ok
  def assert_client!(module \\ @bounded_exchange) do
    if Code.ensure_loaded?(module) do
      :ok
    else
      raise """
      #{inspect(module)} is not available, so raxol_web3 has no bounded read.

      It is compiled only when `mint` is available, because `mint` is an \
      optional dependency of raxol_mcp. It is not optional here: raxol_web3 \
      requires `mint` and every request it makes goes through that module. \
      Either raxol_mcp was compiled in a build without `mint`, or this build \
      kept some of raxol_mcp's mint-guarded modules and dropped others.

      Fix it by rebuilding raxol_mcp with `mint` present. `mix deps.compile \
      --force` is not enough when the stale artefacts are the problem:

          mix deps.clean raxol_mcp mint --build
          mix deps.get
          mix compile
      """
    end
  end
end
