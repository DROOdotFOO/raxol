defmodule Raxol.Core.Accessibility.Announcements do
  use Agent

  @moduledoc """
  Handles screen reader announcements and announcement queue management.
  """

  alias Raxol.Core.Accessibility.AccessibilityServer, as: Server
  alias Raxol.Core.Events.EventManager

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__.Subscriptions)
  end

  @spec add_subscription(reference(), pid()) :: :ok
  def add_subscription(ref, pid) do
    Agent.update(__MODULE__.Subscriptions, &Map.put(&1, ref, pid))
  end

  @spec remove_subscription(reference()) :: :ok
  def remove_subscription(ref) do
    Agent.update(__MODULE__.Subscriptions, &Map.delete(&1, ref))
  end

  @spec get_subscriptions() :: %{reference() => pid()}
  def get_subscriptions do
    Agent.get(__MODULE__.Subscriptions, & &1)
  end

  @doc """
  Make an announcement for screen readers.

  ## Parameters

  * `message` - The message to announce
  * `opts` - Options for the announcement
  * `user_preferences_pid_or_name` - The PID or registered name of the UserPreferences process to use (optional).

  ## Options

  * `:priority` - Priority level (`:low`, `:medium`, `:high`) (default: `:medium`)
  * `:interrupt` - Whether to interrupt current announcements (default: `false`)

  ## Examples

      iex> Announcements.announce("Button clicked")
      :ok

      iex> Announcements.announce("Error occurred", priority: :high, interrupt: true)
      :ok
  """
  @spec announce(String.t(), keyword(), atom() | pid() | nil) :: :ok
  def announce(message, opts \\ [], user_preferences_pid_or_name \\ nil)
      when is_binary(message) do
    validate_user_preferences(user_preferences_pid_or_name)

    handle_announcement(
      should_announce?(user_preferences_pid_or_name),
      message,
      opts,
      user_preferences_pid_or_name
    )

    :ok
  end

  @spec validate_user_preferences(nil) :: no_return()
  defp validate_user_preferences(nil) do
    raise "Accessibility.Announcements.announce/3 must be called with a user_preferences_pid_or_name."
  end

  @spec validate_user_preferences(term()) :: :ok
  defp validate_user_preferences(_user_preferences_pid_or_name), do: :ok

  @spec handle_announcement(
          boolean(),
          String.t(),
          keyword(),
          term()
        ) :: :ok
  defp handle_announcement(
         false,
         _message,
         _opts,
         _user_preferences_pid_or_name
       ),
       do: :ok

  defp handle_announcement(true, message, opts, user_preferences_pid_or_name) do
    process_announcement(message, opts, user_preferences_pid_or_name)
  end

  @spec should_announce?(atom() | pid()) :: boolean()
  defp should_announce?(user_preferences_pid_or_name) do
    Server.should_announce?(user_preferences_pid_or_name)
  end

  @spec process_announcement(String.t(), keyword(), atom() | pid()) :: :ok
  defp process_announcement(message, opts, user_preferences_pid_or_name) do
    announcement = %{
      message: message,
      priority: Keyword.get(opts, :priority, :normal),
      timestamp: System.monotonic_time(:millisecond),
      interrupt: Keyword.get(opts, :interrupt, false)
    }

    # add_announcement/2 returns :ok from GenServer.cast
    :ok = Server.add_announcement(announcement, user_preferences_pid_or_name)

    send_announcement_to_subscribers(announcement)
    :ok = EventManager.dispatch(:accessibility_announce, %{message: message})

    :ok
  end

  @doc """
  Get the next announcement to be read by screen readers for a specific user/context.

  ## Parameters
  * `user_preferences_pid_or_name` - The PID or registered name of the UserPreferences process to use (optional).

  ## Examples
      iex> Announcements.get_next_announcement(:user1)
      "Button clicked"
  """
  @spec get_next_announcement(atom() | pid()) :: String.t() | nil
  def get_next_announcement(user_preferences_pid_or_name) do
    Server.get_next_announcement(user_preferences_pid_or_name)
  end

  @doc """
  Clear all pending announcements.

  ## Examples

      iex> Announcements.clear_announcements()
      :ok
  """
  @spec clear_announcements() :: :ok
  def clear_announcements do
    Server.clear_all_announcements()

    # Send announcements_cleared messages to subscribers
    send_clear_message_to_subscribers()
    :ok
  end

  @doc """
  Clear all pending announcements for a specific user.

  ## Examples

      iex> Announcements.clear_announcements(:user_prefs)
      :ok
  """
  @spec clear_announcements(atom() | pid()) :: :ok
  def clear_announcements(user_preferences_pid_or_name) do
    Server.clear_announcements(user_preferences_pid_or_name)
    :ok
  end

  # --- Private Functions ---

  @spec send_announcement_to_subscribers(map()) :: :ok
  defp send_announcement_to_subscribers(announcement) do
    subscriptions = get_subscriptions()

    Enum.each(subscriptions, fn {ref, pid} ->
      send_to_alive_process(
        Process.alive?(pid),
        pid,
        {:announcement_added, ref, announcement}
      )
    end)
  end

  defp send_clear_message_to_subscribers do
    subscriptions = get_subscriptions()

    Enum.each(subscriptions, fn {ref, pid} ->
      send_to_alive_process(
        Process.alive?(pid),
        pid,
        {:announcements_cleared, ref}
      )
    end)
  end

  defp send_to_alive_process(false, _pid, _message), do: :ok
  defp send_to_alive_process(true, pid, message), do: send(pid, message)
end
