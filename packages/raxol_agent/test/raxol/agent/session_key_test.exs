defmodule Raxol.Agent.SessionKeyTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Code.ShareToken
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.SessionKey

  describe "mint/0" do
    test "produces a key the journal and the share path both accept" do
      key = SessionKey.mint()

      assert SessionKey.valid?(key)
      assert ShareToken.valid_session_id?(key)
    end

    test "distinguishes two keys minted in the same second" do
      keys = for _ <- 1..100, do: SessionKey.mint()

      assert length(Enum.uniq(keys)) == 100
    end

    # The defect this module exists to close. `System.unique_integer/1`
    # restarts from a fresh sequence in every VM, so a key carrying only that
    # names a different session after a restart -- and a client that stored
    # the old one resumes into nothing. The timestamp is what survives.
    test "carries a component that does not reset with the VM" do
      before_s = System.system_time(:second)
      key = SessionKey.mint()

      assert ["sess", seconds, unique] = String.split(key, "-")
      assert {parsed, ""} = Integer.parse(seconds)
      assert parsed >= before_s
      assert {_int, ""} = Integer.parse(unique)
    end
  end

  describe "valid?/1" do
    test "refuses what would escape the journal base" do
      # `FileStore.session_dir/2` joins without sanitizing, so these are the
      # shapes that must never reach it.
      refute SessionKey.valid?("..")
      refute SessionKey.valid?(".")
      refute SessionKey.valid?("../../etc/passwd")
      refute SessionKey.valid?("a/b")
      refute SessionKey.valid?("")
    end

    test "is total" do
      refute SessionKey.valid?(nil)
      refute SessionKey.valid?(:sess)
      refute SessionKey.valid?(123)
      refute SessionKey.valid?(%{})
    end

    # Non-vacuity: the refusals above only mean something if the predicate
    # would otherwise let the traversal through to a real path.
    test "a refused key would have escaped the base" do
      base = "/tmp/raxol-session-key-test"
      escaped = FileStore.session_dir("../../etc", base_dir: base)

      refute SessionKey.valid?("../../etc")
      refute String.starts_with?(Path.expand(escaped), Path.expand(base))
    end
  end
end
