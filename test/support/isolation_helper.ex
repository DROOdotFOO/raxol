defmodule Raxol.Test.IsolationHelper do
  @moduledoc """
  Provides test isolation by resetting global state between tests.

  This module helps ensure that tests don't interfere with each other by
  resetting shared global state (AccessibilityServer, EventManager, UserPreferences)
  to their default states.

  ## Usage

  Call `reset_global_state/0` in your test setup:

      setup do
        Raxol.Test.IsolationHelper.reset_global_state()
        :ok
      end

  Or use `Raxol.Test.IsolatedCase` which does this automatically.
  """

  @doc """
  Resets all global state to ensure test isolation.
  """
  def reset_global_state do
    reset_if_alive(Raxol.Core.Accessibility.AccessibilityServer, :reset, [])
    reset_if_alive(Raxol.Core.Events.EventManager, :clear_handlers, [])
    reset_if_alive(Raxol.Core.UserPreferences, :reset_to_defaults_for_test!, [])
    reset_theme_state()

    reset_if_alive(Raxol.Performance.ETSCacheManager, fn ->
      Raxol.Performance.ETSCacheManager.clear_cache(:style)
      Raxol.Performance.ETSCacheManager.clear_cache(:layout)
    end)

    :ok
  end

  @doc """
  Calls `apply(module, function, args)` only if the named process is alive.
  """
  def reset_if_alive(module, function, args \\ [])

  def reset_if_alive(module, function, args)
      when is_atom(module) and is_atom(function) do
    case Process.whereis(module) do
      nil -> :ok
      _pid -> apply(module, function, args)
    end
  end

  def reset_if_alive(module, fun, _args)
      when is_atom(module) and is_function(fun, 0) do
    case Process.whereis(module) do
      nil -> :ok
      _pid -> fun.()
    end
  end

  defp reset_theme_state do
    Application.delete_env(:raxol, :themes)
    Application.delete_env(:raxol, :current_theme)
  end
end
