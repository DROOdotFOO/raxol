defmodule Raxol.ACP.Console.Inference do
  @moduledoc """
  LLM seam for `Raxol.ACP.Console.Generator`.

  The default implementation, `Inference.Compute`, is the wallet-funded
  Virtuals compute endpoint (OpenAI-compatible chat completions), so the
  offering's own generation is paid from the agent wallet — no separate API
  billing. Configure with:

      config :raxol_acp, :console_inference,
        module: Raxol.ACP.Console.Inference.Compute,
        base_url: "https://compute.virtuals.io/v1",
        api_key: {:system, "VIRTUALS_API_KEY"},
        model: "moonshotai/kimi-k2-0905",
        receive_timeout: 120_000

  `Inference.Static` is the test stub: it returns
  `config :raxol_acp, :console_inference_static` verbatim.
  """

  @callback complete(config :: keyword(), system :: String.t(), user :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Resolved `:console_inference` config with defaults applied."
  @spec config() :: keyword()
  def config do
    Keyword.merge(
      [
        module: __MODULE__.Compute,
        base_url: "https://compute.virtuals.io/v1",
        api_key: {:system, "VIRTUALS_API_KEY"},
        model: "moonshotai/kimi-k2-0905",
        receive_timeout: 120_000
      ],
      Application.get_env(:raxol_acp, :console_inference, [])
    )
  end

  @doc "Run a completion through the configured module."
  @spec complete(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def complete(system, user) do
    cfg = config()
    cfg[:module].complete(cfg, system, user)
  end

  defmodule Compute do
    @moduledoc "OpenAI-compatible chat completions against Virtuals compute."
    @behaviour Raxol.ACP.Console.Inference

    @impl true
    def complete(cfg, system, user) do
      with {:ok, key} <- api_key(cfg[:api_key]) do
        req =
          Req.new(
            base_url: cfg[:base_url],
            auth: {:bearer, key},
            receive_timeout: cfg[:receive_timeout]
          )

        body = %{
          model: cfg[:model],
          messages: [
            %{role: "system", content: system},
            %{role: "user", content: user}
          ]
        }

        case Req.post(req, url: "/chat/completions", json: body) do
          {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => c}} | _]}}} ->
            {:ok, c}

          {:ok, %{status: status, body: body}} ->
            {:error, {:inference_http, status, summarize(body)}}

          {:error, reason} ->
            {:error, {:inference_transport, reason}}
        end
      end
    end

    defp api_key({:system, var}) do
      case System.get_env(var) do
        nil -> {:error, {:inference_no_api_key, var}}
        key -> {:ok, key}
      end
    end

    defp api_key(key) when is_binary(key), do: {:ok, key}
    defp api_key(other), do: {:error, {:inference_bad_api_key, other}}

    defp summarize(body) when is_binary(body), do: binary_part(body, 0, min(200, byte_size(body)))
    defp summarize(body), do: body |> inspect() |> String.slice(0, 200)
  end

  defmodule Static do
    @moduledoc "Test stub: returns `config :raxol_acp, :console_inference_static`."
    @behaviour Raxol.ACP.Console.Inference

    @impl true
    def complete(_cfg, _system, _user) do
      case Application.get_env(:raxol_acp, :console_inference_static) do
        nil -> {:error, :console_inference_static_unset}
        {:error, _} = e -> e
        text when is_binary(text) -> {:ok, text}
      end
    end
  end
end
