defmodule Raxol.Gateway.Pairing do
  @moduledoc """
  DM pairing codes and the gateway's authorization decision.

  A user requests a pairing code (rate-limited per user); confirming a valid,
  unexpired code marks that user paired. `authorize/2` then decides whether a
  route is allowed, in this order:

    1. the route's platform is configured to allow everyone, or
    2. the user is paired, or
    3. the user is in the platform's allowlist, or
    4. the user is in the global allowlist, otherwise
    5. deny.

  Codes are 8 characters from an unambiguous alphabet (no `0/O/1/I/L`), expire
  after `:code_ttl_ms`, and repeated invalid confirms lock confirmation for
  `:lockout_ms` after `:max_failures`. The lockout is global for this slice.

  ## Config keys (all optional)

  `:code_ttl_ms` (1h), `:request_cooldown_ms` (30s), `:max_failures` (5),
  `:lockout_ms` (5m), `:code_length` (8).
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Gateway.Route

  @alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

  @defaults %{
    code_ttl_ms: 60 * 60 * 1000,
    request_cooldown_ms: 30_000,
    max_failures: 5,
    lockout_ms: 5 * 60 * 1000,
    code_length: 8
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Issue a pairing code for a user, or `{:error, :rate_limited}`."
  @spec request_code(GenServer.server(), String.t()) ::
          {:ok, String.t()} | {:error, :rate_limited}
  def request_code(server, user_id),
    do: GenServer.call(server, {:request_code, to_string(user_id)})

  @doc "Confirm a code, pairing its user. Errors: `:invalid`, `:expired`, `:locked_out`."
  @spec confirm(GenServer.server(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid | :expired | :locked_out}
  def confirm(server, code), do: GenServer.call(server, {:confirm, code})

  @doc "Mark a user paired directly (admin path)."
  @spec approve(GenServer.server(), String.t()) :: :ok
  def approve(server, user_id), do: GenServer.call(server, {:approve, to_string(user_id)})

  @doc "Remove a user's pairing."
  @spec revoke(GenServer.server(), String.t()) :: :ok
  def revoke(server, user_id), do: GenServer.call(server, {:revoke, to_string(user_id)})

  @doc "Add a user to the global allowlist, or a platform allowlist with `{:platform, atom}`."
  @spec allow(GenServer.server(), String.t(), :global | {:platform, atom()}) :: :ok
  def allow(server, user_id, scope \\ :global),
    do: GenServer.call(server, {:allow, to_string(user_id), scope})

  @doc "Configure a platform to allow every user."
  @spec allow_platform_all(GenServer.server(), atom()) :: :ok
  def allow_platform_all(server, platform),
    do: GenServer.call(server, {:allow_platform_all, platform})

  @doc "Decide whether a route is authorized."
  @spec authorize(GenServer.server(), Route.t()) :: :allow | :deny
  def authorize(server, %Route{} = route), do: GenServer.call(server, {:authorize, route})

  @doc "Whether a user is paired."
  @spec paired?(GenServer.server(), String.t()) :: boolean()
  def paired?(server, user_id), do: GenServer.call(server, {:paired?, to_string(user_id)})

  # -- BaseManager callbacks --------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    config = Map.merge(@defaults, Map.new(Keyword.take(opts, Map.keys(@defaults))))

    {:ok,
     %{
       config: config,
       pending: %{},
       approved: MapSet.new(),
       allow_global: MapSet.new(),
       allow_platform: %{},
       allow_all_platforms: MapSet.new(),
       last_request: %{},
       failures: 0,
       locked_until: nil
     }}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:request_code, user_id}, _from, state) do
    if rate_limited?(user_id, state) do
      {:reply, {:error, :rate_limited}, state}
    else
      code = gen_code(state.config.code_length)
      entry = %{user_id: user_id, expires_at: now() + state.config.code_ttl_ms}

      state = %{
        state
        | pending: Map.put(state.pending, code, entry),
          last_request: Map.put(state.last_request, user_id, now())
      }

      {:reply, {:ok, code}, state}
    end
  end

  def handle_manager_call({:confirm, code}, _from, state) do
    if locked?(state),
      do: {:reply, {:error, :locked_out}, state},
      else: resolve_confirm(code, state)
  end

  def handle_manager_call({:approve, user_id}, _from, state) do
    {:reply, :ok, %{state | approved: MapSet.put(state.approved, user_id)}}
  end

  def handle_manager_call({:revoke, user_id}, _from, state) do
    {:reply, :ok, %{state | approved: MapSet.delete(state.approved, user_id)}}
  end

  def handle_manager_call({:allow, user_id, :global}, _from, state) do
    {:reply, :ok, %{state | allow_global: MapSet.put(state.allow_global, user_id)}}
  end

  def handle_manager_call({:allow, user_id, {:platform, platform}}, _from, state) do
    set = state.allow_platform |> Map.get(platform, MapSet.new()) |> MapSet.put(user_id)
    {:reply, :ok, %{state | allow_platform: Map.put(state.allow_platform, platform, set)}}
  end

  def handle_manager_call({:allow_platform_all, platform}, _from, state) do
    {:reply, :ok, %{state | allow_all_platforms: MapSet.put(state.allow_all_platforms, platform)}}
  end

  def handle_manager_call({:authorize, route}, _from, state) do
    {:reply, decide(route, state), state}
  end

  def handle_manager_call({:paired?, user_id}, _from, state) do
    {:reply, MapSet.member?(state.approved, user_id), state}
  end

  # -- confirm / authorize ----------------------------------------------------

  defp resolve_confirm(code, state) do
    case Map.get(state.pending, code) do
      nil ->
        {:reply, {:error, :invalid}, register_failure(state)}

      entry ->
        if now() >= entry.expires_at do
          {:reply, {:error, :expired}, drop_code(state, code)}
        else
          state = %{
            state
            | approved: MapSet.put(state.approved, entry.user_id),
              pending: Map.delete(state.pending, code),
              failures: 0
          }

          {:reply, {:ok, entry.user_id}, state}
        end
    end
  end

  defp decide(%Route{platform: platform, user_id: user_id}, state) do
    cond do
      MapSet.member?(state.allow_all_platforms, platform) -> :allow
      allowed_user?(state, platform, user_id && to_string(user_id)) -> :allow
      true -> :deny
    end
  end

  defp allowed_user?(_state, _platform, nil), do: false

  defp allowed_user?(state, platform, user_id) do
    MapSet.member?(state.approved, user_id) or
      in_platform_allow?(state, platform, user_id) or
      MapSet.member?(state.allow_global, user_id)
  end

  defp in_platform_allow?(state, platform, user_id) do
    state.allow_platform |> Map.get(platform, MapSet.new()) |> MapSet.member?(user_id)
  end

  # -- failures / rate limiting -----------------------------------------------

  defp register_failure(state) do
    failures = state.failures + 1

    if failures >= state.config.max_failures do
      %{state | failures: 0, locked_until: now() + state.config.lockout_ms}
    else
      %{state | failures: failures}
    end
  end

  defp locked?(%{locked_until: nil}), do: false
  defp locked?(%{locked_until: until}), do: now() < until

  defp rate_limited?(user_id, state) do
    case Map.get(state.last_request, user_id) do
      nil -> false
      ts -> now() - ts < state.config.request_cooldown_ms
    end
  end

  defp drop_code(state, code), do: %{state | pending: Map.delete(state.pending, code)}

  defp gen_code(length) do
    size = length(@alphabet)

    length
    |> :crypto.strong_rand_bytes()
    |> :binary.bin_to_list()
    |> Enum.map(fn byte -> Enum.at(@alphabet, rem(byte, size)) end)
    |> List.to_string()
  end

  defp now, do: System.monotonic_time(:millisecond)
end
