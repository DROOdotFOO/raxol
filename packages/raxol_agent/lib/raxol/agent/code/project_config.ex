defmodule Raxol.Agent.Code.ProjectConfig do
  @moduledoc """
  Per-repo defaults from `<cwd>/.raxol/config.json`.

  A project can pin which provider and model its agents should use by
  default — handy for a repo that should always run against, say, a specific
  Anthropic model regardless of a contributor's global environment. This is
  a *reference/preference* file only: it names a provider and model, never a
  raw key. Credentials still resolve through `Raxol.Agent.Backend.Resolver`
  (1Password reference, provider env var, or `AI_API_KEY`), so nothing secret
  ever lands in a repo file. Any `key`/`api_key` field is deliberately ignored.

  Precedence at launch is explicit flag > this file > environment
  auto-detect: a `--backend`/`--model` on `mix raxol.code` still wins, and
  with neither a flag nor a pin the resolver auto-detects as before.

  ## File shape

      {
        "provider": "anthropic",
        "model": "claude-sonnet-5",
        "base_url": "https://api.anthropic.com"
      }

  A missing, unreadable, or malformed file is an empty config, never an
  error — a bad `.raxol/config.json` never blocks agent boot.
  """

  @type t :: %{
          optional(:provider) => atom(),
          optional(:model) => String.t(),
          optional(:base_url) => String.t()
        }

  @doc """
  Load `<dir>/.raxol/config.json` into a sanitized config map.

  Only the three known fields (`provider`, `model`, `base_url`) round-trip;
  `provider` is mapped to a known backend atom via `Resolver.harness_from_string/1`
  (an unknown provider name is dropped). Anything else in the file — including
  a stray raw key — is ignored.
  """
  @spec load(String.t()) :: t()
  def load(dir) do
    path = Path.join(dir, ".raxol/config.json")

    with {:ok, binary} <- File.read(path),
         {:ok, json} when is_map(json) <- Jason.decode(binary) do
      parse(json)
    else
      _ -> %{}
    end
  end

  defp parse(json) do
    %{}
    |> put_provider(Map.get(json, "provider"))
    |> put_string(:model, Map.get(json, "model"))
    |> put_string(:base_url, Map.get(json, "base_url"))
  end

  # A provider string only lands when it names a backend the resolver knows;
  # an unknown/typo'd name is dropped so it can never smuggle a bad atom in.
  defp put_provider(config, name) when is_binary(name) do
    case Raxol.Agent.Backend.Resolver.harness_from_string(name) do
      {:ok, provider} -> Map.put(config, :provider, provider)
      :error -> config
    end
  end

  defp put_provider(config, _name), do: config

  defp put_string(config, key, value) when is_binary(value) and value != "",
    do: Map.put(config, key, value)

  defp put_string(config, _key, _value), do: config
end
