defmodule Raxol.Core.Boundary.Evaluation do
  @moduledoc """
  Code-evaluation exposure: the single answer to "does this deployment let a
  submitted string be evaluated on this node?".

  One of the three centralized boundary confinements (PR #569 thread 2); the
  others are `Raxol.Core.Boundary.Path` (path-traversal) and
  `Raxol.Core.Boundary.TermText` (terminal-injection). This one is neither a
  filter nor a resolver -- it never touches untrusted input. It exists because
  one deployment fact was read from two different application keys by the two
  halves of a single rule, and the two halves could disagree.

  ## The invariant

  *A node that evaluates submitted code does not hold signing keys.* Two
  callers enforce it from opposite directions:

    * `Raxol.Playground.Demos.ReplDemo` -- permissive half: evaluates only
      when the flag is on.
    * `Raxol.Payments.Deployment.assert_signing_isolated!/0` -- restrictive
      half: refuses to boot a signing node when the flag is on.

  They MUST read one predicate. Before this module the demo read
  `config :raxol, :repl_exposed` while the payments assertion read
  `config :raxol_payments, :repl_exposed`, so a deployment that set the former
  turned anonymous evaluation on **and** let a co-located signing node boot
  happily -- the invariant held in neither direction (#1045 review).

  ## The flag

  Off unless one of these says otherwise:

    * `RAXOL_REPL_EXPOSED=true` in the environment
    * `config :raxol_core, :repl_exposed, true`

  Both comparisons are exact, so `"1"`, `"TRUE"`, `"true "` and any non-`true`
  term all leave evaluation off. An operator who meant to enable it and
  mistyped gets the safe answer rather than the permissive one.

  Being exposed is necessary but not sufficient for a given surface to
  evaluate: a caller may add its own conditions on top (`ReplDemo` also
  accepts a direct local-terminal launch). Nothing may subtract from it.
  """

  @env_var "RAXOL_REPL_EXPOSED"
  @config_app :raxol_core
  @config_key :repl_exposed

  @doc """
  Whether this deployment has opted in to evaluating submitted code.

  See the module documentation for the exact signals and why there is only
  one predicate.
  """
  @spec exposed?() :: boolean()
  def exposed? do
    System.get_env(@env_var) == "true" or
      Application.get_env(@config_app, @config_key, false) == true
  end

  @doc """
  The environment variable name, for messages that tell an operator how to
  flip the flag. Kept here so no caller hardcodes a name that could drift
  from `exposed?/0`.
  """
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc """
  The `{app, key}` application-environment pair `exposed?/0` reads.
  """
  @spec config_key() :: {atom(), atom()}
  def config_key, do: {@config_app, @config_key}
end
