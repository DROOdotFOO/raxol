defmodule Raxol.Web3.TablesTest do
  use ExUnit.Case, async: true

  alias Raxol.Web3.Tables

  describe "the cursor MAC key" do
    test "is not reachable by enumerating what this node stores" do
      # It was a persistent term, and `:persistent_term.get/0` -- no arguments
      # -- hands back every term on the node, so no caller needed to know what
      # the key was called to walk out with it. The same shape reaches it from
      # an `erl_crash.dump`'s `=persistent_terms` section or an idle remsh.
      key = Tables.cursor_key()

      assert byte_size(key) >= 32

      terms = :persistent_term.get()
      refute Enum.any?(terms, fn {_name, value} -> value == key end)

      # The table ids this module DOES publish stay published: they are not
      # credentials, and the lock-free read is the whole point of them.
      assert Enum.any?(terms, fn {name, _value} -> name == {Tables, :buckets} end)
    end

    test "is owned privately, so reading it takes the accessor and nothing else" do
      # `:private` means the owner alone may read: any other process holding
      # the tid gets `ArgumentError` rather than the key. Walking every table
      # on the node and dumping it is therefore not a path to it, and neither
      # is the public half this module does publish.
      key = Tables.cursor_key()
      owner = Process.whereis(Tables)
      owned = Enum.filter(:ets.all(), &(:ets.info(&1, :owner) == owner))

      {private, public} =
        Enum.split_with(owned, &(:ets.info(&1, :protection) == :private))

      assert [secrets] = private
      assert_raise ArgumentError, fn -> :ets.tab2list(secrets) end

      for table <- public do
        refute Enum.any?(:ets.tab2list(table), &(key in Tuple.to_list(&1))),
               "the cursor key is readable from #{inspect(:ets.info(table, :name))}"
      end
    end

    test "is stable across reads, so a cursor verifies against the one that minted it" do
      assert Tables.cursor_key() == Tables.cursor_key()
    end
  end
end
