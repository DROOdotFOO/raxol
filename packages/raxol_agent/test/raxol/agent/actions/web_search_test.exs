defmodule Raxol.Agent.Actions.WebSearchTest do
  # Provider selection reads process-global env vars and application config.
  use ExUnit.Case, async: false

  alias Raxol.Agent.Actions.WebSearch

  @env ~w(BRAVE_SEARCH_API_KEY BRAVE_API_KEY KAGI_API_KEY
          RAXOL_BRAVE_SEARCH_OP RAXOL_KAGI_OP RAXOL_PROVIDERS)

  # The action resolves a key from env vars, from a 1Password reference in the
  # provider store, and from application config, so a test that left any of
  # those to the host machine would pass or fail depending on whose laptop ran
  # it. Everything is cleared, and `RAXOL_PROVIDERS` is pointed at a path that
  # does not exist so the reference store reads empty instead of the developer's
  # real `~/.raxol/providers.json`.
  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)

    System.put_env(
      "RAXOL_PROVIDERS",
      Path.join(
        System.tmp_dir!(),
        "raxol-absent-providers-#{System.unique_integer([:positive])}.json"
      )
    )

    pinned = Application.get_env(:raxol_agent, :web_search_provider)
    Application.delete_env(:raxol_agent, :web_search_provider)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      case pinned do
        nil -> Application.delete_env(:raxol_agent, :web_search_provider)
        id -> Application.put_env(:raxol_agent, :web_search_provider, id)
      end
    end)

    :ok
  end

  defp json_transport(status, payload) do
    fn _url, _opts ->
      {:ok,
       %{
         status: status,
         headers: %{"content-type" => ["application/json"]},
         chunks: [Jason.encode!(payload)],
         cancel: fn -> :ok end
       }}
    end
  end

  defp refusing_transport do
    fn url, _opts -> flunk("searched #{url} with no credentials configured") end
  end

  test "without a key it says so and names the variables to set" do
    assert {:error, {:web_search_not_configured, hint}} =
             WebSearch.call(
               %{query: "elixir telemetry"},
               %{http_transport: refusing_transport()}
             )

    assert hint =~ "BRAVE_SEARCH_API_KEY"
    assert hint =~ "KAGI_API_KEY"
  end

  test "returns ranked results with title, url and snippet" do
    System.put_env("BRAVE_SEARCH_API_KEY", "test-key")

    payload = %{
      "web" => %{
        "results" => [
          %{
            "title" => "Telemetry",
            "url" => "https://hexdocs.pm/telemetry",
            "description" => "Dynamic dispatching library"
          },
          %{
            "title" => "Telemetry Metrics",
            "url" => "https://hexdocs.pm/telemetry_metrics",
            "description" => "Metric definitions"
          }
        ]
      }
    }

    assert {:ok, result} =
             WebSearch.call(
               %{query: "elixir telemetry"},
               %{http_transport: json_transport(200, payload)}
             )

    assert result.provider == "brave"
    assert result.trust == "untrusted"

    assert result.results == [
             %{
               title: "Telemetry",
               url: "https://hexdocs.pm/telemetry",
               snippet: "Dynamic dispatching library"
             },
             %{
               title: "Telemetry Metrics",
               url: "https://hexdocs.pm/telemetry_metrics",
               snippet: "Metric definitions"
             }
           ]
  end

  test "honours the requested limit" do
    System.put_env("BRAVE_SEARCH_API_KEY", "test-key")

    results =
      Enum.map(1..10, fn n ->
        %{"title" => "r#{n}", "url" => "https://example.com/#{n}", "description" => "s#{n}"}
      end)

    assert {:ok, result} =
             WebSearch.call(
               %{query: "q", limit: 3},
               %{http_transport: json_transport(200, %{"web" => %{"results" => results}})}
             )

    assert length(result.results) == 3
  end

  test "drops a Kagi related-searches bundle, which is not a fetchable result" do
    System.put_env("KAGI_API_KEY", "test-key")
    Application.put_env(:raxol_agent, :web_search_provider, :kagi)

    payload = %{
      "data" => [
        %{
          "t" => 0,
          "title" => "Raxol",
          "url" => "https://raxol.io",
          "snippet" => "Terminal framework"
        },
        %{"t" => 1, "list" => ["raxol tui", "raxol agent"]}
      ]
    }

    assert {:ok, result} =
             WebSearch.call(
               %{query: "raxol"},
               %{http_transport: json_transport(200, payload)}
             )

    assert result.results == [
             %{title: "Raxol", url: "https://raxol.io", snippet: "Terminal framework"}
           ]
  end

  test "a pinned provider with no key fails on that provider alone" do
    System.put_env("BRAVE_SEARCH_API_KEY", "test-key")
    Application.put_env(:raxol_agent, :web_search_provider, :kagi)

    assert {:error, {:web_search_not_configured, hint}} =
             WebSearch.call(
               %{query: "q"},
               %{http_transport: refusing_transport()}
             )

    assert hint =~ "KAGI_API_KEY"
    refute hint =~ "BRAVE_SEARCH_API_KEY"
  end

  test "reports a provider rejection instead of an empty result list" do
    System.put_env("BRAVE_SEARCH_API_KEY", "test-key")

    assert {:error, {:search_provider_error, 429}} =
             WebSearch.call(
               %{query: "q"},
               %{http_transport: json_transport(429, %{"error" => "rate limited"})}
             )
  end

  test "reports an undecodable provider response instead of no results" do
    System.put_env("BRAVE_SEARCH_API_KEY", "test-key")

    transport = fn _url, _opts ->
      {:ok,
       %{
         status: 200,
         headers: %{"content-type" => ["text/html"]},
         chunks: ["<html>maintenance</html>"],
         cancel: fn -> :ok end
       }}
    end

    assert {:error, :search_response_unparsable} =
             WebSearch.call(%{query: "q"}, %{http_transport: transport})
  end
end
