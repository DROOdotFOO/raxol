defmodule Raxol.Core.Plugins.Core.NotificationPlugin do
  @moduledoc """
  Core plugin responsible for handling notifications (:notify).
  Relies on an implementation of Raxol.System.Interaction for OS interactions.
  """


  @behaviour Raxol.Core.Runtime.Plugins.Plugin

  # Default implementation module
  @default_interaction_module Raxol.System.InteractionImpl

  @impl Raxol.Core.Runtime.Plugins.Plugin
  def init(_config) do
    # Determine interaction module at runtime
    interaction_mod =
      Application.get_env(
        :raxol,
        :system_interaction_module,
        @default_interaction_module
      )

    Raxol.Core.Runtime.Log.info(
      "Notification Plugin initialized (Interaction: #{interaction_mod})."
    )

    # Store the module in the plugin state and initialize other fields
    initial_state = %{
      interaction_module: interaction_mod,
      name: "notification",
      enabled: true,
      # Default config
      config: %{style: "minimal"},
      # Initialize notifications list
      notifications: []
    }

    {:ok, initial_state}
  end

  @impl Raxol.Core.Runtime.Plugins.Plugin
  def get_commands do
    [
      {:notify, :handle_command, 2}
    ]
  end

  @impl Raxol.Core.Runtime.Plugins.Plugin
  # Handle :notify command. Expects [title_string, message_string] as args.
  def handle_command(:notify, [title, message], state)
      when is_binary(title) and is_binary(message) do
    interaction_mod = state.interaction_module
    data_map = %{title: title, message: message}
    handle_notify(interaction_mod, data_map, state)
  end

  # Catch-all for incorrect args if a command somehow gets routed here
  # with a different signature than what get_commands implies.
  def handle_command(command_name, args, state) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "NotificationPlugin :handle_command received unexpected command " <>
        to_string(command_name) <>
        " with args format: " <>
        inspect(args),
      %{command: command_name, args: args}
    )

    {:error, {:unexpected_command_args, command_name, args}, state}
  end

  # Internal handler for :notify
  # Retrieves interaction_mod from state
  defp handle_notify(interaction_mod, data, state) do
    message = Map.get(data, :message, "Notification")
    title = Map.get(data, :title, "Raxol Notification")

    Raxol.Core.Runtime.Log.debug(
      "NotificationPlugin: Sending notification - Title: " <>
        to_string(title) <> ", Message: " <> to_string(message)
    )

    os_lookup_result =
      lookup_notification_command(interaction_mod, title, message)

    # Handle pre-execution errors first
    case os_lookup_result do
      {:error, reason_tuple} ->
        handle_notification_error(reason_tuple, state)

      {executable, args, os_name} ->
        execute_notification_command(
          interaction_mod,
          executable,
          args,
          os_name,
          state
        )
    end
  end

  defp lookup_notification_command(interaction_mod, title, message) do
    case interaction_mod.get_os_type() do
      {:unix, :linux} ->
        lookup_linux_notification(interaction_mod, title, message)

      {:unix, :darwin} ->
        lookup_darwin_notification(interaction_mod, title, message)

      {:win32, :nt} ->
        lookup_windows_notification(interaction_mod, message)

      other_os ->
        {:error, {:unsupported_os, other_os}}
    end
  end

  defp lookup_linux_notification(interaction_mod, title, message) do
    case interaction_mod.find_executable("notify-send") do
      nil -> {:error, {:command_not_found, :notify_send}}
      path -> {path, [title, message], :linux}
    end
  end

  defp lookup_darwin_notification(interaction_mod, title, message) do
    case interaction_mod.find_executable("osascript") do
      nil ->
        {:error, {:command_not_found, :osascript}}

      path ->
        script =
          case title do
            nil -> ~s(display notification \"#{message}\")
            _ -> ~s(display notification \"#{message}\" with title \"#{title}\")
          end

        {path, ["-e", script], :macos}
    end
  end

  defp lookup_windows_notification(interaction_mod, message) do
    case interaction_mod.find_executable("powershell") do
      nil ->
        {:error, {:command_not_found, :powershell}}

      path ->
        script =
          ~s(Import-Module BurntToast; New-BurntToastNotification -Text "#{message}")

        {path, ["-NoProfile", "-Command", script], :windows}
    end
  end

  # Helper to handle specific notification errors
  defp handle_notification_error(reason_tuple, state) do
    case reason_tuple do
      {:command_not_found, :notify_send} ->
        Raxol.Core.Runtime.Log.error(
          "NotificationPlugin: Command 'notify-send' not found. Please install it."
        )

        {:error, {:command_not_found, :notify_send}, state}

      {:command_not_found, :osascript} ->
        Raxol.Core.Runtime.Log.error(
          "NotificationPlugin: Command 'osascript' not found."
        )

        {:error, {:command_not_found, :osascript}, state}

      {:command_not_found, :powershell} ->
        Raxol.Core.Runtime.Log.error(
          "NotificationPlugin: Command 'powershell' not found."
        )

        {:error, {:command_not_found, :powershell}, state}

      {:unsupported_os, os_tuple} ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "NotificationPlugin: Desktop notifications not supported on this OS: #{inspect(os_tuple)}",
          %{}
        )

        {:ok, state, :notification_skipped_unsupported_os}
    end
  end

  defp execute_notification_command(
         interaction_mod,
         executable,
         args,
         os_name,
         state
       ) do
    case run_notification_command(
           interaction_mod,
           executable,
           args,
           os_name,
           state
         ) do
      {:ok, result} ->
        result

      {:error, {e, stacktrace}} ->
        handle_command_exception(e, stacktrace, state)

      {:error, reason} ->
        handle_command_error(reason, state)
    end
  end

  defp run_notification_command(
         interaction_mod,
         executable,
         args,
         os_name,
         state
       ) do
    Raxol.Core.ErrorHandling.safe_call(fn ->
      log_command_execution(executable, args)

      interaction_mod.system_cmd(executable, args, stderr_to_stdout: true)
      |> handle_command_result(os_name, state)
    end)
  end

  defp log_command_execution(executable, args) do
    Raxol.Core.Runtime.Log.debug(
      "Executing notification command: #{executable} with args: #{inspect(args)}"
    )
  end

  defp handle_command_result({_output, 0}, os_name, state) do
    success_atom = get_success_atom_for_os(os_name)
    {:ok, state, success_atom}
  end

  defp handle_command_result({output, exit_code}, _os_name, state) do
    Raxol.Core.Runtime.Log.error(
      "Notification command failed. Exit Code: #{exit_code}, Output: #{output}"
    )

    {:error, {:command_failed, exit_code, output}, state}
  end

  defp get_success_atom_for_os(:linux), do: :notification_sent_linux
  defp get_success_atom_for_os(:macos), do: :notification_sent_macos
  defp get_success_atom_for_os(:windows), do: :notification_sent_windows

  defp handle_command_exception(e, stacktrace, state) do
    Raxol.Core.Runtime.Log.error(
      "NotificationPlugin: Error executing notification command: #{inspect(e)}"
    )

    {:error, {:command_exception, Exception.format(:error, e, stacktrace)},
     state}
  end

  defp handle_command_error(reason, state) do
    Raxol.Core.Runtime.Log.error(
      "NotificationPlugin: Error executing notification command: #{inspect(reason)}"
    )

    {:error, {:command_error, reason}, state}
  end

  @impl Raxol.Core.Runtime.Plugins.Plugin
  def terminate(_reason, _state) do
    Raxol.Core.Runtime.Log.info(
      "Notification Plugin terminated (Behaviour callback)."
    )

    :ok
  end

  @impl Raxol.Core.Runtime.Plugins.Plugin
  def enable(state), do: {:ok, state}

  @impl Raxol.Core.Runtime.Plugins.Plugin
  def disable(state), do: {:ok, state}

  @impl Raxol.Core.Runtime.Plugins.Plugin
  def filter_event(event, state), do: {:ok, event, state}

  # Defensive: handle_command/2 returns an error indicating incorrect arity
  # Add a wrapper for backward compatibility with tests
  @doc """
  Wrapper for handle_command/2 for backward compatibility. Delegates to handle_command/3 if possible.
  """
  def handle_command([a, b], state) when is_binary(a) and is_binary(b) do
    handle_command(:notify, [a, b], state)
  end

  def handle_command(_args, _state) do
    {:error, :invalid_arity,
     "NotificationPlugin.handle_command/2 is not supported for these arguments. Use handle_command/3 with state."}
  end
end
