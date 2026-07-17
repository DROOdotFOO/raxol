# Ported (as new coverage, upstream had no dedicated ext test file) from the
# conventions of the MIT `f1729/agent_client_protocol` test suite
# (c) 2025 f1729; see NOTICE.md. Targets
# Raxol.AgentClientProtocol.Schema.Ext.{ExtRequest,ExtNotification,ExtResponse}.
defmodule Raxol.AgentClientProtocol.Schema.ExtTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Schema.Ext.ExtNotification
  alias Raxol.AgentClientProtocol.Schema.Ext.ExtRequest
  alias Raxol.AgentClientProtocol.Schema.Ext.ExtResponse

  describe "ExtRequest" do
    test "new/2 builds a struct with empty _meta" do
      req = ExtRequest.new("_myext/doThing", %{"foo" => "bar"})
      assert %ExtRequest{method: "_myext/doThing", params: %{"foo" => "bar"}, _meta: %{}} = req
    end

    test "from_map/1 is total: valid map" do
      assert {:ok, %ExtRequest{method: "_x/y", params: 1, _meta: %{}}} =
               ExtRequest.from_map(%{"method" => "_x/y", "params" => 1})
    end

    test "from_map/1 is total: missing method never raises" do
      assert {:error, :invalid_ext_request} = ExtRequest.from_map(%{"params" => 1})
      assert {:error, :invalid_ext_request} = ExtRequest.from_map(%{})
      assert {:error, :invalid_ext_request} = ExtRequest.from_map("not a map")
      assert {:error, :invalid_ext_request} = ExtRequest.from_map(nil)
    end

    test "from_map/1 folds unknown wire fields into _meta (forward-compat)" do
      assert {:ok, %ExtRequest{method: "_x/y", params: nil, _meta: meta}} =
               ExtRequest.from_map(%{"method" => "_x/y", "requestId" => "abc123"})

      assert meta == %{"requestId" => "abc123"}
    end

    test "from_map/1 merges an explicit _meta object with folded unknown fields" do
      assert {:ok, %ExtRequest{_meta: meta}} =
               ExtRequest.from_map(%{
                 "method" => "_x/y",
                 "_meta" => %{"raxol.io/trace" => "t1"},
                 "extra" => true
               })

      assert meta == %{"raxol.io/trace" => "t1", "extra" => true}
    end

    test "never invokes String.to_atom on wire-derived data" do
      # No atom-derived keys anywhere in the decode path: this must not
      # exhaust the atom table across repeated calls with fresh strings.
      for i <- 1..50 do
        assert {:ok, _} = ExtRequest.from_map(%{"method" => "_x/#{i}", "field_#{i}" => i})
      end
    end

    test "Jason.Encoder round-trips method/params and re-emits _meta" do
      req = %ExtRequest{method: "_x/y", params: %{"a" => 1}, _meta: %{"extra" => true}}
      encoded = Jason.encode!(req)
      assert {:ok, decoded} = Jason.decode(encoded)
      assert decoded["method"] == "_x/y"
      assert decoded["params"] == %{"a" => 1}
      assert decoded["extra"] == true
    end
  end

  describe "ExtNotification" do
    test "new/2 builds a struct with empty _meta" do
      note = ExtNotification.new("_myext/ping", nil)
      assert %ExtNotification{method: "_myext/ping", params: nil, _meta: %{}} = note
    end

    test "from_map/1 is total and folds unknown fields into _meta" do
      assert {:ok, %ExtNotification{method: "_x/y", params: nil, _meta: %{"z" => 1}}} =
               ExtNotification.from_map(%{"method" => "_x/y", "z" => 1})

      assert {:error, :invalid_ext_notification} = ExtNotification.from_map(%{})
      assert {:error, :invalid_ext_notification} = ExtNotification.from_map(:not_a_map)
    end

    test "Jason.Encoder never raises on a bare struct" do
      note = ExtNotification.new("_x/y", [1, 2, 3])

      assert {:ok, %{"method" => "_x/y", "params" => [1, 2, 3]}} =
               note |> Jason.encode!() |> Jason.decode()
    end
  end

  describe "ExtResponse" do
    test "new/1 wraps an arbitrary term" do
      assert %ExtResponse{data: %{"ok" => true}} = ExtResponse.new(%{"ok" => true})
    end

    test "from_json/1 is total and always succeeds (any term is valid data)" do
      assert {:ok, %ExtResponse{data: nil}} = ExtResponse.from_json(nil)
      assert {:ok, %ExtResponse{data: 42}} = ExtResponse.from_json(42)
      assert {:ok, %ExtResponse{data: %{"a" => 1}}} = ExtResponse.from_json(%{"a" => 1})
    end

    test "to_json/1 unwraps transparently (no envelope)" do
      assert ExtResponse.to_json(%ExtResponse{data: %{"a" => 1}}) == %{"a" => 1}
      assert ExtResponse.to_json(%ExtResponse{data: nil}) == nil
    end

    test "Jason.Encoder mirrors to_json/1 (transparent, unwrapped encoding)" do
      assert Jason.encode!(%ExtResponse{data: %{"a" => 1}}) == Jason.encode!(%{"a" => 1})
      assert Jason.encode!(%ExtResponse{data: nil}) == "null"
    end

    # --- Regression test for the upstream defect ---
    #
    # Upstream `ACP.Client`/`ACP.Agent`'s `__using__`-injected default
    # `ext_method/1` constructed `%ACP.ExtResponse{value: nil}`, but the
    # struct's only field is `:data` — every un-overridden `_ext/*` request
    # raised `KeyError: key :value not found`. This proves the canonical
    # "un-overridden extension" response is field-consistent and returns
    # cleanly instead of crashing.
    test "empty/0 is the crash-proof un-overridden-ext default response" do
      response = ExtResponse.empty()

      assert %ExtResponse{data: nil} = response
      # The historical bug used the wrong field name; assert the actual
      # struct field agrees with construction, to_json, and encoding.
      assert response.data == nil
      assert ExtResponse.to_json(response) == nil
      assert Jason.encode!(response) == "null"

      # This is what an un-overridden ext_method/1 callback should return —
      # confirm it type-checks as the same {:ok, t()} shape from_json/1
      # produces, so callers can treat both paths uniformly.
      assert {:ok, ^response} = ExtResponse.from_json(nil)
    end

    test "constructing %ExtResponse{value: ...} is not possible (struct has no :value field)" do
      assert_raise KeyError, fn ->
        struct!(ExtResponse, value: nil)
      end
    end
  end
end
