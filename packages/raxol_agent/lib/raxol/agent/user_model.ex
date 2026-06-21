defmodule Raxol.Agent.UserModel do
  @moduledoc """
  A derived, per-user model of who the agent is talking to.

  The UserModel reasons over past conversation items on an auxiliary model to
  build a short representation of the user (preferences, goals, habits) and keeps
  it per `user_id`. It is a `Raxol.Agent.Memory` provider whose contribution is a
  `build_user_context/1` block, injected into the LAST user message rather than
  the system prompt, so refreshing it does not invalidate the cacheable system
  prefix. Its `search/2`, `store/2`, and `forget/2` are no-ops.

  `refresh_async/4` derives in a background `Task` off the GenServer so the
  foreground turn never waits on the model call; `refresh/4` is the synchronous
  form for explicit use and tests. The auxiliary model is configured the same way
  as `Raxol.Agent.SelfImprove`: `backend` (an `AIBackend`, defaults to Mock),
  `model`, and `backend_opts`.

  Refreshing on a turn cadence is left to the runtime, which calls
  `refresh_async/4` after a turn, mirroring `SelfImprove.after_turn/3`.
  """

  use Raxol.Core.Behaviours.BaseManager
  use Raxol.Agent.Memory

  alias Raxol.Agent.Auxiliary

  @default_backend Raxol.Agent.Backend.Mock

  @derive_prompt """
  From the conversation below, write a short profile of the user: their
  preferences, goals, and working habits. Be concise and concrete. Write only the
  profile, no preamble.
  """

  # -- Public API -------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The stored context string for `user_id`, or `nil`."
  @spec get_context(GenServer.server(), String.t()) :: String.t() | nil
  def get_context(server, user_id), do: GenServer.call(server, {:get, user_id})

  @doc "Set a user's context directly (bypasses derivation)."
  @spec put_context(GenServer.server(), String.t(), String.t()) :: :ok
  def put_context(server, user_id, context), do: GenServer.call(server, {:put, user_id, context})

  @doc "Derive and store a user's context synchronously from conversation items."
  @spec refresh(GenServer.server(), String.t(), [map()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def refresh(server, user_id, items, opts \\ []) do
    GenServer.call(server, {:refresh, user_id, items, opts})
  end

  @doc "Derive a user's context in the background; the store updates when it completes."
  @spec refresh_async(GenServer.server(), String.t(), [map()], keyword()) :: :ok
  def refresh_async(server, user_id, items, opts \\ []) do
    GenServer.cast(server, {:refresh, user_id, items, opts})
  end

  # -- Memory behaviour -------------------------------------------------------

  @impl Raxol.Agent.Memory
  def search(_query, _opts), do: []

  @impl Raxol.Agent.Memory
  def store(record, _opts), do: {:ok, record}

  @impl Raxol.Agent.Memory
  def forget(_id, _opts), do: :ok

  @impl Raxol.Agent.Memory
  def build_user_context(opts) do
    server = Keyword.get(opts, :server, __MODULE__)

    case Keyword.get(opts, :user_id) do
      nil -> nil
      user_id -> user_id |> then(&get_context(server, &1)) |> wrap()
    end
  end

  defp wrap(nil), do: nil
  defp wrap(context), do: "## About the user\n\n" <> context

  # -- BaseManager callbacks --------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    {:ok,
     %{
       contexts: %{},
       backend: opts[:backend],
       model: opts[:model],
       backend_opts: opts[:backend_opts] || [],
       auxiliary: opts[:auxiliary],
       default: opts[:default],
       available?: opts[:available?]
     }}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:get, user_id}, _from, state) do
    {:reply, Map.get(state.contexts, user_id), state}
  end

  def handle_manager_call({:put, user_id, context}, _from, state) do
    {:reply, :ok, store_context(state, user_id, context)}
  end

  def handle_manager_call({:refresh, user_id, items, opts}, _from, state) do
    case derive(items, config(state, opts)) do
      {:ok, context} -> {:reply, {:ok, context}, store_context(state, user_id, context)}
      error -> {:reply, error, state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:refresh, user_id, items, opts}, state) do
    server = self()
    config = config(state, opts)

    Task.start(fn ->
      case derive(items, config) do
        {:ok, context} -> GenServer.cast(server, {:store, user_id, context})
        _ -> :ok
      end
    end)

    {:noreply, state}
  end

  def handle_manager_cast({:store, user_id, context}, state) do
    {:noreply, store_context(state, user_id, context)}
  end

  # -- derivation -------------------------------------------------------------

  defp derive(items, config) do
    messages = [
      %{role: :system, content: @derive_prompt},
      %{role: :user, content: transcript(items)}
    ]

    {backend, opts} = resolve_backend(config)

    case backend.complete(messages, opts) do
      {:ok, %{content: content}} when is_binary(content) -> {:ok, String.trim(content)}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :derive_failed}
    end
  end

  defp transcript(items), do: Enum.map_join(items, "\n", &line/1)

  defp line(item) do
    data = Map.get(item, :data, %{})
    text = Map.get(data, :content) || Map.get(data, :text) || ""
    "#{Map.get(data, :role) || Map.get(item, :created_by) || "?"}: #{text}"
  end

  defp config(state, opts) do
    %{
      backend: Keyword.get(opts, :backend, state.backend),
      model: Keyword.get(opts, :model, state.model),
      backend_opts: Keyword.get(opts, :backend_opts, state.backend_opts),
      auxiliary: Keyword.get(opts, :auxiliary, state.auxiliary),
      default: Keyword.get(opts, :default, state.default),
      available?: Keyword.get(opts, :available?, state.available?)
    }
  end

  # An explicit backend or model wins. Otherwise route the user-model task through
  # the auxiliary resolver, degrading to the default backend if no slot is available.
  defp resolve_backend(config) do
    if config.backend || config.model do
      {config.backend || @default_backend, backend_opts(config)}
    else
      case Auxiliary.select(:user_model, aux_opts(config)) do
        {:ok, module, opts} -> {module, Keyword.merge(config.backend_opts, opts)}
        {:error, _reason} -> {@default_backend, config.backend_opts}
      end
    end
  end

  defp aux_opts(config) do
    [auxiliary: config.auxiliary, default: config.default, available?: config.available?]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp backend_opts(%{model: nil, backend_opts: base}), do: base
  defp backend_opts(%{model: model, backend_opts: base}), do: Keyword.put(base, :model, model)

  defp store_context(state, user_id, context) do
    %{state | contexts: Map.put(state.contexts, user_id, context)}
  end
end
