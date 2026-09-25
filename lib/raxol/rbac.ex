defmodule Raxol.RBAC do
  @moduledoc """
  Role-Based Access Control for Raxol.

  Provides role definition and permission checking.

  ## Example

      Raxol.RBAC.define_role(:admin, [:read_all, :write_all, :delete_all])
      Raxol.RBAC.define_role(:user, [:read_own, :write_own])

      if Raxol.RBAC.can?(user, :delete_all) do
        delete_resource()
      end
  """

  use Agent

  @doc """
  Start the RBAC agent, linked, for a supervision tree.

  Without one, the public API starts the agent unlinked on first use.
  """
  def start_link(_opts \\ []) do
    Agent.start_link(&initial_state/0, name: __MODULE__)
  end

  @doc """
  Define a role with a list of permissions.

  ## Example

      Raxol.RBAC.define_role(:admin, [:read_all, :write_all, :delete_all])
  """
  @spec define_role(atom(), list(atom())) :: :ok
  def define_role(role, permissions)
      when is_atom(role) and is_list(permissions) do
    _ = ensure_started()

    Agent.update(__MODULE__, fn state ->
      put_in(state, [:roles, role], MapSet.new(permissions))
    end)
  end

  @doc """
  Assign a role to a user.

  ## Example

      Raxol.RBAC.assign_role(user, :admin)
  """
  @spec assign_role(map() | String.t(), atom()) :: :ok
  def assign_role(user, role) when is_atom(role) do
    _ = ensure_started()
    user_id = get_user_id(user)

    Agent.update(__MODULE__, fn state ->
      current_roles = Map.get(state.user_roles, user_id, MapSet.new())
      put_in(state, [:user_roles, user_id], MapSet.put(current_roles, role))
    end)
  end

  @doc """
  Check if a user has a specific permission.

  ## Example

      if Raxol.RBAC.can?(user, :delete_all) do
        delete_resource()
      end
  """
  @spec can?(map() | String.t(), atom()) :: boolean()
  def can?(user, permission) when is_atom(permission) do
    _ = ensure_started()
    user_id = get_user_id(user)

    Agent.get(__MODULE__, fn state ->
      user_roles = Map.get(state.user_roles, user_id, MapSet.new())

      Enum.any?(user_roles, fn role ->
        role_permissions = Map.get(state.roles, role, MapSet.new())
        MapSet.member?(role_permissions, permission)
      end)
    end)
  end

  @doc """
  Get all permissions for a user.

  ## Example

      permissions = Raxol.RBAC.get_permissions(user)
  """
  @spec get_permissions(map() | String.t()) :: list(atom())
  def get_permissions(user) do
    _ = ensure_started()
    user_id = get_user_id(user)

    Agent.get(__MODULE__, fn state ->
      user_roles = Map.get(state.user_roles, user_id, MapSet.new())

      user_roles
      |> Enum.flat_map(fn role ->
        state.roles
        |> Map.get(role, MapSet.new())
        |> MapSet.to_list()
      end)
      |> Enum.uniq()
    end)
  end

  @doc """
  Get all roles for a user.

  ## Example

      roles = Raxol.RBAC.get_roles(user)
  """
  @spec get_roles(map() | String.t()) :: list(atom())
  def get_roles(user) do
    _ = ensure_started()
    user_id = get_user_id(user)

    Agent.get(__MODULE__, fn state ->
      state.user_roles
      |> Map.get(user_id, MapSet.new())
      |> MapSet.to_list()
    end)
  end

  @doc """
  Remove a role from a user.

  ## Example

      Raxol.RBAC.remove_role(user, :admin)
  """
  @spec remove_role(map() | String.t(), atom()) :: :ok
  def remove_role(user, role) when is_atom(role) do
    _ = ensure_started()
    user_id = get_user_id(user)

    Agent.update(__MODULE__, fn state ->
      current_roles = Map.get(state.user_roles, user_id, MapSet.new())
      put_in(state, [:user_roles, user_id], MapSet.delete(current_roles, role))
    end)
  end

  # Private helpers

  defp ensure_started do
    Raxol.Core.Utils.GenServerHelpers.ensure_started(
      __MODULE__,
      fn -> Agent.start(&initial_state/0, name: __MODULE__) end
    )
  end

  defp initial_state, do: %{roles: %{}, user_roles: %{}}

  defp get_user_id(%{id: id}), do: to_string(id)
  defp get_user_id(%{"id" => id}), do: to_string(id)
  defp get_user_id(user) when is_binary(user), do: user
  defp get_user_id(_), do: "unknown"
end
