defmodule Raxol.Broker.Test.ExecutorIdentity do
  @moduledoc """
  Impersonate `Raxol.Broker.Executor` in the calling test process.

  The journal only grants its claim to a process whose proc_lib initial call
  is `{Raxol.Broker.Executor, :init, 1}`, and `Raxol.Broker.Executor.Place`
  only verifies receipts against the key in the Executor's own process
  dictionary. Tests that drive the journal or `Place` directly need both, so
  this module writes them into the caller's process dictionary by hand.

  That is exactly the deliberate-subversion path the broker's threat model
  excludes: the BEAM cannot stop code that writes another module's private
  process state on purpose. It exists for tests only and lives in
  `test/support`, so it is never compiled into the library.
  """

  import ExUnit.Assertions

  alias Raxol.Broker.Journal

  @doc """
  Make the calling process look like an Executor and claim `journal` for it.

  Sets `:"$initial_call"` to `{Raxol.Broker.Executor, :init, 1}`; with
  `opts[:key]`, also puts that receipt key where the Executor keeps its own.
  Asserts the claim succeeds.
  """
  @spec assume!(Journal.server(), keyword()) :: :ok
  def assume!(journal, opts \\ []) do
    Process.put(:"$initial_call", {Raxol.Broker.Executor, :init, 1})

    case Keyword.fetch(opts, :key) do
      {:ok, key} -> Process.put({Raxol.Broker.Executor, :receipt_key}, key)
      :error -> :ok
    end

    assert Journal.claim(journal) == :ok
    :ok
  end
end
