defmodule Raxol.Agent.UserModelTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Backend.Mock
  alias Raxol.Agent.Memory.Manager
  alias Raxol.Agent.UserModel

  setup do
    name = :"um_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {UserModel, :start_link, [[name: name]]}})
    %{server: name}
  end

  describe "derivation" do
    test "refresh derives a context from items via the aux model and stores it", %{server: s} do
      items = [
        %{type: :message, data: %{role: :user, content: "I prefer Elixir and terse commits"}}
      ]

      assert {:ok, "prefers Elixir, terse commits"} =
               UserModel.refresh(s, "u1", items,
                 backend: Mock,
                 backend_opts: [response: "prefers Elixir, terse commits"]
               )

      assert UserModel.get_context(s, "u1") == "prefers Elixir, terse commits"
    end

    test "a derivation error leaves the stored context unchanged", %{server: s} do
      UserModel.put_context(s, "u1", "existing")

      assert {:error, _} =
               UserModel.refresh(s, "u1", [], backend: Mock, backend_opts: [error: :down])

      assert UserModel.get_context(s, "u1") == "existing"
    end
  end

  describe "build_user_context/1" do
    test "wraps the stored context in a labeled block", %{server: s} do
      UserModel.put_context(s, "u1", "likes pipes")

      assert UserModel.build_user_context(server: s, user_id: "u1") ==
               "## About the user\n\nlikes pipes"
    end

    test "is nil for an unknown or missing user", %{server: s} do
      assert UserModel.build_user_context(server: s, user_id: "nope") == nil
      assert UserModel.build_user_context(server: s) == nil
    end
  end

  describe "Manager.enrich_user_context injection" do
    test "appends to the LAST user message, leaving the system prefix intact", %{server: s} do
      UserModel.put_context(s, "u1", "likes pipes")

      messages = [
        %{role: :system, content: "SYSTEM PREFIX"},
        %{role: :user, content: "first"},
        %{role: :assistant, content: "ok"},
        %{role: :user, content: "second"}
      ]

      out = Manager.enrich_user_context(messages, {UserModel, [server: s, user_id: "u1"]})

      assert Enum.at(out, 0) == %{role: :system, content: "SYSTEM PREFIX"}
      assert Enum.at(out, 1).content == "first"
      assert List.last(out).content == "second\n\n## About the user\n\nlikes pipes"
    end

    test "nil provider and no-user-message are no-ops", %{server: s} do
      assert Manager.enrich_user_context([%{role: :user, content: "x"}], nil) ==
               [%{role: :user, content: "x"}]

      system_only = [%{role: :system, content: "x"}]

      assert Manager.enrich_user_context(system_only, {UserModel, [server: s, user_id: "u1"]}) ==
               system_only
    end
  end
end
