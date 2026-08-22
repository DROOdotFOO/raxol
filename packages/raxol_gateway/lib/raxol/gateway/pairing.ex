defmodule Raxol.Gateway.Pairing do
  @moduledoc """
  DM pairing codes and the gateway's authorization decision.

  A user requests a pairing code (rate-limited per user); confirming a valid,
  unexpired code marks that user paired. `authorize/2` then decides whether a
  route is allowed, in this order:

    1. the route's platform is configured to allow everyone, or
    2. the user holds a PAIRING covering the route's platform, or
    3. the user holds an ALLOWLIST entry covering the route's platform, otherwise
    4. deny.

  Codes are 8 characters from an unambiguous alphabet (no `0/O/1/I/L`), expire
  after `:code_ttl_ms`, and repeated invalid confirms lock confirmation for
  `:lockout_ms` after `:max_failures`. The lockout is global for this slice.

  ## Every grant carries a scope

  A user id means nothing on its own. Telegram ids are integers, Discord ids are
  snowflakes, email ids are addresses -- three unrelated namespaces, and no
  authority reconciles them. "User 12345" is a different person on each, so a
  grant that names only an id is a grant whose subject is undefined.

  So a scope is an argument, never a default:

      :global            # this id, on EVERY connected platform
      {:platform, :telegram}   # this id, there, and nowhere else

  `request_code/3`, `approve/3`, `revoke/3` and `allow/3` all require one.
  `{:platform, _}` is the answer that means something; `:global` is the one you
  have to type, and it is only safe when you know the connected platforms' id
  spaces cannot collide -- which for a single-platform deployment is trivially
  true and for any other is a claim worth making deliberately.

  A pairing is scoped where the CODE was issued, not where it was confirmed: the
  scope is bound into the pending entry by `request_code/3`, so a code minted for
  Telegram cannot be redeemed into a Discord grant.

  `{:platform, :global}` is refused rather than silently collapsing into the
  cross-platform bucket, and so is a `:global` key in `:platform_users` -- a grant
  filed under "per platform" must not turn out to admit every platform.

  ## Config keys (all optional)

  `:code_ttl_ms` (1h), `:request_cooldown_ms` (30s), `:max_failures` (5),
  `:lockout_ms` (5m), `:code_length` (8).

  ## Seeds, and why the configured posture is not runtime state

  `:allow_platforms`, `:allowed_users` and `:platform_users` are applied at
  `init_manager/1` on every start, including a supervisor RESTART. The
  runtime-mutable calls (`allow/3`, `allow_platform_all/2`, `approve/3`) exist
  alongside them and are lost on restart, which is what in-memory pairing means.

  `:allowed_users` seeds the `:global` scope and `:platform_users` seeds the
  per-platform ones, so the config surface carries the same distinction the
  runtime calls do.

  The split matters because the two failure modes are not symmetric. Losing a
  DM pairing costs one user one re-pair. Losing the configured posture is total
  and silent in BOTH directions: an `:open` deployment starts denying every
  message forever, and an enforcing one revokes every allowlist entry it was
  given. Neither re-announces itself, because the boot that announced it already
  happened. Seeding from opts means a crash restores the deployment's intent
  rather than an empty server that no caller can tell from a configured one.

      {Raxol.Gateway.Pairing, name: :gw_pairing, allow_platforms: [:telegram]}
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Gateway.Route

  @typedoc """
  Where a grant applies. `{:platform, atom}` admits the id on that platform
  alone; `:global` admits it on every connected platform, which is only sound
  when their id namespaces cannot collide.
  """
  @type scope :: :global | {:platform, atom()}

  # `:global` is the cross-platform bucket's own key, so a platform of that name
  # would file a scoped grant into it. nil/booleans are atoms too, and a platform
  # resolved from a lookup that missed is the likely way one arrives.
  defguardp is_platform(p) when is_atom(p) and p not in [:global, nil, true, false]

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

  @doc """
  Issue a pairing code granting `scope` when confirmed, or
  `{:error, :rate_limited}`.

  The scope is bound HERE, not at `confirm/2`: the code is a bearer token, and
  what it is worth has to be fixed by the party that minted it. Otherwise a code
  issued to admit someone on Telegram could be redeemed for a grant somewhere
  else entirely.
  """
  @spec request_code(GenServer.server(), String.t(), scope()) ::
          {:ok, String.t()} | {:error, :rate_limited}
  def request_code(server, user_id, scope),
    do: GenServer.call(server, {:request_code, to_string(user_id), scope_key(scope)})

  @doc """
  Confirm a code, pairing its user in the scope the code was issued for.

  Errors: `:invalid`, `:expired`, `:locked_out`.
  """
  @spec confirm(GenServer.server(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid | :expired | :locked_out}
  def confirm(server, code), do: GenServer.call(server, {:confirm, code})

  @doc "Mark a user paired in `scope` directly (admin path)."
  @spec approve(GenServer.server(), String.t(), scope()) :: :ok
  def approve(server, user_id, scope),
    do: GenServer.call(server, {:approve, to_string(user_id), scope_key(scope)})

  @doc """
  Remove a user's pairing in `scope`.

  Scoped, so revoking a Telegram pairing leaves a Discord one standing. Revoking
  `:global` removes only the cross-platform grant, not the per-platform ones --
  each was granted separately and each has to go separately.
  """
  @spec revoke(GenServer.server(), String.t(), scope()) :: :ok
  def revoke(server, user_id, scope),
    do: GenServer.call(server, {:revoke, to_string(user_id), scope_key(scope)})

  @doc "Add a user to the allowlist for `scope`."
  @spec allow(GenServer.server(), String.t(), scope()) :: :ok
  def allow(server, user_id, scope),
    do: GenServer.call(server, {:allow, to_string(user_id), scope_key(scope)})

  @doc "Configure a platform to allow every user."
  @spec allow_platform_all(GenServer.server(), atom()) :: :ok
  def allow_platform_all(server, platform) when is_platform(platform),
    do: GenServer.call(server, {:allow_platform_all, platform})

  @doc "Decide whether a route is authorized."
  @spec authorize(GenServer.server(), Route.t()) :: :allow | :deny
  def authorize(server, %Route{} = route), do: GenServer.call(server, {:authorize, route})

  @doc """
  Whether a pairing would admit `user_id` on `platform`.

  True for a pairing scoped to that platform OR a `:global` one, which is the
  same question `authorize/2` asks -- not "does a record exist somewhere".
  """
  @spec paired?(GenServer.server(), String.t(), atom()) :: boolean()
  def paired?(server, user_id, platform) when is_platform(platform),
    do: GenServer.call(server, {:paired?, to_string(user_id), platform})

  # The scope, as the key its grants are filed under. Raises rather than
  # returning an error tuple: these are the arguments of a caller who has decided
  # who to admit, so a malformed one is a bug at that call site and should stop
  # there rather than travel into the server as a grant nobody meant.
  defp scope_key(:global), do: :global
  defp scope_key({:platform, platform}) when is_platform(platform), do: platform

  defp scope_key(other) do
    raise ArgumentError,
          "invalid pairing scope #{inspect(other)}; expected :global or {:platform, atom}"
  end

  # -- BaseManager callbacks --------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    config = Map.merge(@defaults, Map.new(Keyword.take(opts, Map.keys(@defaults))))

    {:ok,
     %{
       config: config,
       pending: %{},
       # Both are scope-keyed the same way -- `:global`, or a platform atom --
       # and both are read by `in_scope?/3`. They stay separate because their
       # lifetimes differ: `allowed` is rebuilt from opts on every restart,
       # `paired` is not.
       paired: %{},
       allowed: seed_allowed(opts),
       allow_all_platforms: MapSet.new(opt_list(opts, :allow_platforms)),
       last_request: %{},
       failures: 0,
       locked_until: nil
     }}
  end

  defp opt_list(opts, key), do: opts |> Keyword.get(key, []) |> List.wrap()

  # `:allowed_users` is the cross-platform bucket, `:platform_users` the scoped
  # ones -- the same distinction the runtime calls make, so config and code are
  # not two vocabularies for one decision.
  defp seed_allowed(opts) do
    global = MapSet.new(opt_list(opts, :allowed_users), &to_string/1)
    seeded = if MapSet.size(global) == 0, do: %{}, else: %{global: global}

    opts |> opt_list(:platform_users) |> Enum.reduce(seeded, &seed_platform/2)
  end

  # Repeated platform keys UNION rather than overwrite. A keyword list admits
  # duplicates and collecting `into: %{}` would keep only the last, silently
  # dropping every id named earlier -- a lockout indistinguishable from never
  # having configured them, which is the ambiguity the Console's `known_keys/1`
  # refuses one level up for a typo'd key.
  #
  # A `:global` key here is refused rather than merged: it would file ids written
  # under "per platform" into the bucket that admits every platform, which is a
  # silent widening of exactly the grant this scoping exists to narrow. Failing
  # init is right -- a Pairing that will not start beats one that over-grants.
  defp seed_platform({platform, users}, acc) when is_platform(platform) do
    ids = MapSet.new(users, &to_string/1)
    Map.update(acc, platform, ids, fn existing -> MapSet.union(existing, ids) end)
  end

  defp seed_platform({platform, _users}, _acc) do
    raise ArgumentError,
          ":platform_users cannot be keyed on #{inspect(platform)}; " <>
            "use :allowed_users for a cross-platform grant"
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:request_code, user_id, scope_key}, _from, state) do
    if rate_limited?(user_id, state) do
      {:reply, {:error, :rate_limited}, state}
    else
      code = gen_code(state.config.code_length)

      entry = %{
        user_id: user_id,
        scope_key: scope_key,
        expires_at: now() + state.config.code_ttl_ms
      }

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

  def handle_manager_call({:approve, user_id, scope_key}, _from, state) do
    {:reply, :ok, %{state | paired: grant(state.paired, scope_key, user_id)}}
  end

  def handle_manager_call({:revoke, user_id, scope_key}, _from, state) do
    {:reply, :ok, %{state | paired: ungrant(state.paired, scope_key, user_id)}}
  end

  def handle_manager_call({:allow, user_id, scope_key}, _from, state) do
    {:reply, :ok, %{state | allowed: grant(state.allowed, scope_key, user_id)}}
  end

  def handle_manager_call({:allow_platform_all, platform}, _from, state) do
    {:reply, :ok, %{state | allow_all_platforms: MapSet.put(state.allow_all_platforms, platform)}}
  end

  def handle_manager_call({:authorize, route}, _from, state) do
    {:reply, decide(route, state), state}
  end

  def handle_manager_call({:paired?, user_id, platform}, _from, state) do
    {:reply, in_scope?(state.paired, platform, user_id), state}
  end

  # -- scoped grants ----------------------------------------------------------

  defp grant(map, scope_key, user_id) do
    Map.update(map, scope_key, MapSet.new([user_id]), &MapSet.put(&1, user_id))
  end

  defp ungrant(map, scope_key, user_id) do
    case Map.get(map, scope_key) do
      nil -> map
      set -> Map.put(map, scope_key, MapSet.delete(set, user_id))
    end
  end

  # A grant covers a route when it names that route's platform, or when it was
  # deliberately made cross-platform. Nothing else matches, so an id granted on
  # Telegram is not the same subject as the identical id arriving from Discord.
  defp in_scope?(map, platform, user_id) do
    member?(map, platform, user_id) or member?(map, :global, user_id)
  end

  defp member?(map, scope_key, user_id) do
    case Map.get(map, scope_key) do
      nil -> false
      set -> MapSet.member?(set, user_id)
    end
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
          # The scope comes off the pending entry, so redeeming a code cannot
          # widen what the party who minted it decided to hand out.
          state = %{
            state
            | paired: grant(state.paired, entry.scope_key, entry.user_id),
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
      allowed_user?(state, platform, scalar_id(user_id)) -> :allow
      true -> :deny
    end
  end

  # `authorize/2` runs INSIDE this server on a route an adapter built from wire
  # input, and `Route.new/1` validates nothing. A `to_string/1` over whatever the
  # payload carried would raise here rather than at the caller, and this server is
  # the first `:rest_for_one` child -- so one malformed id would take the session
  # supervisor and the router down with it, on every retry, for every chat. An id
  # that is not a scalar cannot match a seeded allowlist entry anyway, so treating
  # it as absent is the same answer without the crash.
  defp scalar_id(id) when is_binary(id), do: id
  defp scalar_id(id) when is_integer(id), do: Integer.to_string(id)
  defp scalar_id(_id), do: nil

  defp allowed_user?(_state, _platform, nil), do: false

  defp allowed_user?(state, platform, user_id) do
    in_scope?(state.paired, platform, user_id) or
      in_scope?(state.allowed, platform, user_id)
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
