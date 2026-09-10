defmodule RaxolPlayground.ReleaseManifestCache do
  @moduledoc false

  use GenServer

  require Logger

  alias RaxolPlayground.ReleaseManifest

  @default_url "https://github.com/DROOdotFOO/raxol/releases/download/raxol-cli-channel/latest.json"
  @fresh_ms :timer.seconds(60)
  @stale_ms :timer.minutes(5)

  @type entry :: %{body: binary(), etag: binary(), stale?: boolean()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec get(GenServer.server()) :: {:ok, entry()} | {:error, term()}
  def get(server \\ __MODULE__) do
    GenServer.call(server, :get, 10_000)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       url: Keyword.get(opts, :url, @default_url),
       body: nil,
       etag: nil,
       fresh_ms: Keyword.get(opts, :fresh_ms, @fresh_ms),
       stale_ms: Keyword.get(opts, :stale_ms, @stale_ms),
       fresh_until: 0,
       stale_until: 0
     }}
  end

  @impl true
  def handle_call(:get, _from, state) do
    now = System.monotonic_time(:millisecond)

    if state.body && now < state.fresh_until do
      {:reply, {:ok, entry(state, false)}, state}
    else
      refresh(state, now)
    end
  end

  defp refresh(state, now) do
    headers = if state.etag, do: [{"if-none-match", state.etag}], else: []

    result =
      Req.get(state.url,
        headers: headers,
        retry: false,
        decode_body: false,
        receive_timeout: 5_000,
        connect_options: [timeout: 3_000]
      )

    case result do
      {:ok, %Req.Response{status: 304}} when is_binary(state.body) ->
        state = refresh_deadlines(state, now)
        {:reply, {:ok, entry(state, false)}, state}

      {:ok, %Req.Response{status: 200, body: body, headers: response_headers}}
      when is_binary(body) ->
        case ReleaseManifest.validate(body) do
          :ok ->
            etag = response_headers |> Map.get("etag", []) |> List.first() || etag(body)

            state =
              state
              |> Map.merge(%{body: body, etag: etag})
              |> refresh_deadlines(now)

            {:reply, {:ok, entry(state, false)}, state}

          {:error, reason} ->
            stale_or_error(state, now, reason)
        end

      {:ok, %Req.Response{status: status}} ->
        stale_or_error(state, now, {:http_status, status})

      {:error, reason} ->
        stale_or_error(state, now, reason)
    end
  end

  defp stale_or_error(state, now, reason) do
    if state.body && now < state.stale_until do
      Logger.warning("Serving stale CLI release manifest: #{inspect(reason)}")
      {:reply, {:ok, entry(state, true)}, state}
    else
      {:reply, {:error, reason}, state}
    end
  end

  defp refresh_deadlines(state, now) do
    %{
      state
      | fresh_until: now + state.fresh_ms,
        stale_until: now + state.fresh_ms + state.stale_ms
    }
  end

  defp entry(state, stale?) do
    %{body: state.body, etag: state.etag, stale?: stale?}
  end

  defp etag(body) do
    digest = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    ~s("#{digest}")
  end
end
