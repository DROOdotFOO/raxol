defmodule RaxolPlayground.ReleaseManifestCache do
  @moduledoc false

  require Logger

  alias RaxolPlayground.ReleaseManifest

  @table __MODULE__
  @url "https://github.com/DROOdotFOO/raxol/releases/download/raxol-cli-channel/latest.json"
  @fresh_ms :timer.seconds(60)
  @stale_ms :timer.minutes(5)

  @type entry :: %{body: binary(), etag: binary(), stale?: boolean()}

  @spec get(keyword()) :: {:ok, entry()} | {:error, term()}
  def get(opts \\ []) do
    fresh_ms = Keyword.get(opts, :fresh_ms, @fresh_ms)
    stale_ms = Keyword.get(opts, :stale_ms, @stale_ms)
    now = System.monotonic_time(:millisecond)

    case lookup() do
      {:ok, entry, fetched_at} when now - fetched_at < fresh_ms ->
        {:ok, Map.put(entry, :stale?, false)}

      stale ->
        refresh(opts, stale, now, fresh_ms + stale_ms)
    end
  end

  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.delete(@table, :manifest)
    :ok
  end

  defp refresh(opts, stale, now, stale_limit_ms) do
    headers =
      case stale do
        {:ok, %{etag: etag}, _fetched_at} -> [{"if-none-match", etag}]
        :miss -> []
      end

    request_options =
      [
        url: @url,
        headers: headers,
        retry: false,
        decode_body: false,
        receive_timeout: 5_000,
        connect_options: [timeout: 3_000]
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.get(request_options) do
      {:ok, %Req.Response{status: 304}} ->
        refresh_stale(stale, now)

      {:ok, %Req.Response{status: 200, body: body} = response} when is_binary(body) ->
        case ReleaseManifest.validate(body) do
          :ok ->
            etag = response.headers |> Map.get("etag", []) |> List.first() || etag(body)
            entry = %{body: body, etag: etag}
            store(entry, now)
            {:ok, Map.put(entry, :stale?, false)}

          {:error, reason} ->
            stale_or_error(stale, now, stale_limit_ms, reason)
        end

      {:ok, %Req.Response{status: status}} ->
        stale_or_error(stale, now, stale_limit_ms, {:http_status, status})

      {:error, reason} ->
        stale_or_error(stale, now, stale_limit_ms, reason)
    end
  end

  defp refresh_stale({:ok, entry, _fetched_at}, now) do
    store(entry, now)
    {:ok, Map.put(entry, :stale?, false)}
  end

  defp refresh_stale(:miss, _now), do: {:error, :unexpected_not_modified}

  defp stale_or_error({:ok, entry, fetched_at}, now, stale_limit_ms, reason)
       when now - fetched_at < stale_limit_ms do
    Logger.warning("Serving stale CLI release manifest: #{inspect(reason)}")
    {:ok, Map.put(entry, :stale?, true)}
  end

  defp stale_or_error(_stale, _now, _stale_limit_ms, reason), do: {:error, reason}

  defp lookup do
    ensure_table()

    case :ets.lookup(@table, :manifest) do
      [{:manifest, entry, fetched_at}] -> {:ok, entry, fetched_at}
      [] -> :miss
    end
  end

  defp store(entry, fetched_at) do
    ensure_table()
    :ets.insert(@table, {:manifest, entry, fetched_at})
    :ok
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      _ref ->
        @table
    end
  end

  defp etag(body) do
    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    ~s("#{digest}")
  end
end
