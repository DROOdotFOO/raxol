defmodule Raxol.Symphony.Runners.Codex.Auth do
  @moduledoc """
  Resolves which credential the Codex runner spawns with, and whether it is
  present, from the `codex.auth` config block.

  Symphony does not drive Codex's interactive/OAuth sign-in -- that browser
  flow is owned by the `codex` CLI (`codex login`). This module only *selects*
  the credential the CLI already holds and reports whether it is there, so an
  unauthenticated run fails fast at preflight instead of stalling mid-turn.

  Three modes, resolved from config (which stores only references, never the
  secret itself):

    * `:inherit` (default) -- inject nothing; the spawned process sees the
      ambient environment, exactly as before this existed. Considered
      authenticated if `auth.json` exists under the effective `CODEX_HOME`
      (`$CODEX_HOME` or `~/.codex`) or `OPENAI_API_KEY` is set.
    * `:api_key` -- read the key from the env var named by `:api_key_env`
      (default `OPENAI_API_KEY`) at spawn time and inject it as
      `OPENAI_API_KEY`. Authenticated iff that var is set and non-empty.
    * `:codex_home` -- inject `CODEX_HOME` pointing at `:codex_home`.
      Authenticated iff `auth.json` exists under it.

  `resolve/1`, `gate/2`, and `emit/1` are the seams: `resolve/1` reads the
  environment/filesystem once and returns a plain map; `gate/2` applies
  `require_login`; `emit/1` publishes `[:raxol, :symphony, :codex, :auth]`
  telemetry (`%{mode, authenticated?, source}` -- never the secret).
  """

  @type resolved :: %{
          mode: :inherit | :api_key | :codex_home,
          source: :inherit | :api_key | :codex_home,
          authenticated?: boolean(),
          env: [{charlist(), charlist()}]
        }

  @default_codex_home "~/.codex"
  @auth_file "auth.json"

  @doc """
  Resolves the effective credential from a `codex` config map.

  Reads env vars and the filesystem at call time (spawn time), so the answer
  reflects the environment the child will actually inherit. Pure w.r.t. its
  argument; the `:env` list is ready to hand to `Port.open`'s `{:env, _}`.
  """
  @spec resolve(map()) :: resolved()
  def resolve(codex) when is_map(codex) do
    codex |> Map.get(:auth, %{}) |> do_resolve()
  end

  defp do_resolve(%{mode: :api_key} = auth) do
    var = Map.get(auth, :api_key_env, "OPENAI_API_KEY")

    case env_value(var) do
      nil ->
        %{mode: :api_key, source: :api_key, authenticated?: false, env: []}

      value ->
        %{
          mode: :api_key,
          source: :api_key,
          authenticated?: true,
          env: [{~c"OPENAI_API_KEY", String.to_charlist(value)}]
        }
    end
  end

  defp do_resolve(%{mode: :codex_home, codex_home: home}) when is_binary(home) do
    %{
      mode: :codex_home,
      source: :codex_home,
      authenticated?: home_authenticated?(home),
      env: [{~c"CODEX_HOME", String.to_charlist(home)}]
    }
  end

  defp do_resolve(_inherit_or_unset) do
    home = env_value("CODEX_HOME") || @default_codex_home

    %{
      mode: :inherit,
      source: :inherit,
      authenticated?: home_authenticated?(home) or env_value("OPENAI_API_KEY") != nil,
      env: []
    }
  end

  @doc """
  Applies `require_login`: fails when the credential is absent and the config
  demands one, otherwise `:ok`.
  """
  @spec gate(map(), resolved()) :: :ok | {:error, :codex_unauthenticated}
  def gate(codex, %{authenticated?: authenticated?}) when is_map(codex) do
    require_login = get_in(codex, [:auth, :require_login]) == true

    if require_login and not authenticated? do
      {:error, :codex_unauthenticated}
    else
      :ok
    end
  end

  @doc """
  Emits `[:raxol, :symphony, :codex, :auth]` telemetry for a resolved
  credential. Metadata is `%{mode, authenticated?, source}` -- never the secret.
  """
  @spec emit(resolved()) :: :ok
  def emit(%{mode: mode, authenticated?: authenticated?, source: source}) do
    :telemetry.execute(
      [:raxol, :symphony, :codex, :auth],
      %{count: 1},
      %{mode: mode, authenticated?: authenticated?, source: source}
    )
  end

  defp home_authenticated?(home) when is_binary(home) do
    File.exists?(Path.join(Path.expand(home), @auth_file))
  end

  defp env_value(var) when is_binary(var) do
    case System.get_env(var) do
      value when is_binary(value) and value != "" -> value
      _absent -> nil
    end
  end
end
