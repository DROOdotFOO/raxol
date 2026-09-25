defmodule Raxol.Security.UserContext do
  @moduledoc """
  Refactored Security User Context module with GenServer-based state management.

  This module provides user context management for security operations,
  eliminating Process dictionary usage in favor of supervised state.

  ## Migration Notes

  This module replaces Process.get(:current_user) calls in encryption modules
  with proper OTP-compliant state management.
  """

  alias Raxol.Security.UserContext.ContextServer, as: Server

  defp ensure_server_started do
    Raxol.Core.Utils.GenServerHelpers.ensure_started(
      Server,
      fn -> GenServer.start(Server, [], name: Server) end
    )
  end

  @doc """
  Sets the current user for security operations.

  ## Examples

      iex> set_current_user("alice")
      :ok
  """
  def set_current_user(user_id) do
    ensure_server_started()
    Server.set_current_user(user_id)
  end

  @doc """
  Gets the current user for security operations.

  ## Examples

      iex> get_current_user()
      "alice"
  """
  def get_current_user do
    ensure_server_started()
    Server.get_current_user()
  end

  @doc """
  Clears the current user.

  ## Examples

      iex> clear_current_user()
      :ok
  """
  def clear_current_user do
    ensure_server_started()
    Server.clear_current_user()
  end

  @doc """
  Sets security context for the current operation.

  ## Examples

      iex> set_context(:encryption_key_id, "key_123")
      :ok
  """
  def set_context(key, value) do
    ensure_server_started()
    Server.set_context(key, value)
  end

  @doc """
  Gets security context for the current operation.

  ## Examples

      iex> get_context(:encryption_key_id)
      "key_123"
  """
  def get_context(key, default \\ nil) do
    ensure_server_started()
    Server.get_context(key, default)
  end

  @doc """
  Records an audit log entry for the current user.

  ## Examples

      iex> audit_log(:encrypt_data, %{file: "sensitive.txt"})
      :ok
  """
  def audit_log(action, details \\ %{}) do
    ensure_server_started()
    Server.audit_log(action, details)
    :ok
  end

  @doc """
  Executes a function with a specific user context.

  ## Examples

      iex> with_user("bob", fn ->
      ...>   # Operations will be performed as "bob"
      ...>   encrypt_file("data.txt")
      ...> end)
  """
  def with_user(user_id, fun) do
    ensure_server_started()

    case Raxol.Core.ErrorHandling.safe_call(fn ->
           execute_with_user_context(user_id, fun)
         end) do
      {:ok, result} ->
        result

      {:error, reason} ->
        # Attempt to clear current user on error
        Server.clear_current_user()
        {:error, reason}
    end
  end

  defp execute_with_user_context(user_id, fun) do
    previous_user = Server.get_current_user()
    Server.set_current_user(user_id)
    result = fun.()
    restore_previous_user(previous_user)
    result
  end

  defp restore_previous_user("system"), do: Server.clear_current_user()
  defp restore_previous_user(user), do: Server.set_current_user(user)
end
