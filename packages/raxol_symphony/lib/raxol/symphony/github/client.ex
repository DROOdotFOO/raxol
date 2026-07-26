defmodule Raxol.Symphony.GitHub.Client do
  @moduledoc "Shared Req builder for the GitHub REST API (tracker + evidence)."

  @doc """
  Builds a Req client with GitHub REST defaults. Callers resolve
  base_url/token/plug/adapter/receive_timeout from their own config source.
  """
  @spec build(String.t(), String.t() | nil, term(), term(), pos_integer()) :: Req.Request.t()
  def build(base_url, token, plug, adapter, receive_timeout) do
    base = [
      base_url: base_url,
      headers: [
        {"accept", "application/vnd.github+json"},
        {"authorization", "Bearer #{token}"},
        {"x-github-api-version", "2022-11-28"},
        {"user-agent", "raxol-symphony"}
      ],
      receive_timeout: receive_timeout,
      retry: false
    ]

    base = if plug, do: Keyword.put(base, :plug, plug), else: base
    base = if adapter, do: Keyword.put(base, :adapter, adapter), else: base

    Req.new(base)
  end
end
