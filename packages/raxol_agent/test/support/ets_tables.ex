defmodule Raxol.Agent.Test.EtsTables do
  @moduledoc """
  Teardown for the named ETS tables a test hands to an adapter.

  These tests name a table and let `Raxol.Agent.Cache.Ets` or
  `Raxol.Agent.ThreadLog.Ets` create it lazily on first use, which makes the
  creating process -- usually the test process itself -- the table's owner.
  ERTS reaps an owner's tables as that process exits, and the reaping runs
  concurrently with `on_exit`, which ExUnit executes in its own process once
  the test process is already down.

  That makes the obvious teardown a check-then-act race:

      if :ets.whereis(table) != :undefined, do: :ets.delete(table)

  `whereis` resolves, the reaper frees the table, and the delete raises
  `ArgumentError`. It took `Raxol.Agent.ThreadLogRouterTest` red on a loaded CI
  runner with every assertion passing and the failure inside `on_exit`.

  Deleting is still worth doing -- a table created inside a process that
  outlives the test would otherwise sit there for the rest of the run -- so
  drop the guard and tolerate the one outcome that is the goal state anyway.
  """

  @doc """
  Deletes `tables`, tolerating any that are already gone.

  Named tables only. `:ets.whereis/1` is specified for atoms, so a tid or any
  other term would make the rescue below raise a second, different
  `ArgumentError` and discard the original -- pointing the failure at this
  helper instead of the caller. The guard turns that into a
  `FunctionClauseError` at the call site instead.

  A table that is still live and still refuses the delete is a real badarg and
  is reraised. Every adapter in this repo creates `:public` tables, where a
  non-owner delete succeeds, so that branch is unreachable today; it exists so
  that an adapter switching to `:protected` fails loudly rather than silently
  leaking. `test/ets_tables_test.exs` covers it.

  Mirrors `Raxol.Symphony.Test.EtsTables`, which cannot use this one:
  `test/support` is not shipped with the package. Keep the two `drop/1` bodies
  identical.
  """
  def drop(tables) when is_list(tables), do: Enum.each(tables, &drop/1)

  def drop(table) when is_atom(table) do
    :ets.delete(table)
    :ok
  rescue
    error in ArgumentError ->
      if :ets.whereis(table) == :undefined,
        do: :ok,
        else: reraise(error, __STACKTRACE__)
  end
end
