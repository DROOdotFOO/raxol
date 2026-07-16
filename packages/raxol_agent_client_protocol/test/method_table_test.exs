# Tests pinning Raxol.AgentClientProtocol.MethodTable per
# scratchpad/specs/acp-methodtable-design.md §8 ("Tests that pin the
# design") and its G1 gate-review fix log. Not a port of any upstream
# f1729 test file -- this module and its table have no upstream analogue.
defmodule Raxol.AgentClientProtocol.MethodTableTest do
  # async: false -- the atom-count property tests below assert a tight
  # bound on global atom growth (:erlang.system_info(:atom_count) is
  # node-wide); running concurrently with other async test modules that
  # also compile/load code would make that bound flaky.
  use ExUnit.Case, async: false

  alias Raxol.AgentClientProtocol.MethodTable

  @meta_path Path.expand("../priv/schema-oracle/v1/meta.json", __DIR__)

  # -- §8.1 Oracle diff ---------------------------------------------------------

  describe "oracle diff" do
    @tag :oracle
    test "table's client->agent wire set matches meta.json agentMethods ∪ protocolMethods" do
      meta = read_meta!()

      expected =
        MapSet.new(Map.values(meta["agentMethods"]) ++ Map.values(meta["protocolMethods"]))

      actual =
        MethodTable.rows()
        |> Enum.filter(&(&1.direction in [:client_to_agent, :both] and &1.ext == nil))
        |> MapSet.new(& &1.wire)

      assert MapSet.equal?(actual, expected),
             "table/oracle mismatch: table-only=#{inspect(MapSet.difference(actual, expected))}, " <>
               "oracle-only=#{inspect(MapSet.difference(expected, actual))}"
    end

    @tag :oracle
    test "table's agent->client wire set matches meta.json clientMethods" do
      meta = read_meta!()
      expected = MapSet.new(Map.values(meta["clientMethods"]))

      actual =
        MethodTable.rows()
        |> Enum.filter(&(&1.direction == :agent_to_client and &1.ext == nil))
        |> MapSet.new(& &1.wire)

      assert MapSet.equal?(actual, expected),
             "table/oracle mismatch: table-only=#{inspect(MapSet.difference(actual, expected))}, " <>
               "oracle-only=#{inspect(MapSet.difference(expected, actual))}"
    end

    @tag :oracle
    test "every oracle method has the direction/kind meta.json implies" do
      meta = read_meta!()

      by_wire = Map.new(MethodTable.rows(), &{&1.wire, &1})

      for wire <- Map.values(meta["agentMethods"]) do
        row = Map.fetch!(by_wire, wire)
        assert row.direction in [:client_to_agent, :both], "#{wire} should be client_to_agent"
      end

      for wire <- Map.values(meta["clientMethods"]) do
        row = Map.fetch!(by_wire, wire)
        assert row.direction == :agent_to_client, "#{wire} should be agent_to_client"
      end

      for wire <- Map.values(meta["protocolMethods"]) do
        row = Map.fetch!(by_wire, wire)
        assert row.direction == :both, "#{wire} should be :both"
        assert row.layer == :protocol, "#{wire} should be layer: :protocol"
      end

      # session/cancel is a wire-shaped agent method (present in
      # meta.json["agentMethods"]) but is layer: :session_control per the
      # G2 delta (§6.0) -- callback is nil, same as :protocol rows.
      cancel_row = Map.fetch!(by_wire, "session/cancel")
      assert cancel_row.layer == :session_control
      assert cancel_row.callback == nil
      assert cancel_row.kind == :notification
    end

    @tag :oracle
    test "session/cancel and $/cancel_request are both callback: nil (no app dispatch surface)" do
      by_wire = Map.new(MethodTable.rows(), &{&1.wire, &1})

      assert Map.fetch!(by_wire, "session/cancel").callback == nil
      assert Map.fetch!(by_wire, "$/cancel_request").callback == nil
    end
  end

  # -- §8.2-ish: table shape / invariant sanity (direct, not via Code.compile_string) --

  describe "row shape" do
    test "every row has all nine expected keys" do
      expected_keys =
        MapSet.new([
          :wire,
          :direction,
          :kind,
          :callback,
          :params,
          :result,
          :capability,
          :layer,
          :ext
        ])

      for row <- MethodTable.rows() do
        assert MapSet.new(Map.keys(row)) == expected_keys,
               "row #{inspect(row.wire)} has wrong shape"
      end
    end

    test "every params/result module referenced exists and exports from_json/1 (design doc invariant 6)" do
      for row <- MethodTable.rows(), mod <- [row.params, row.result], mod != nil do
        assert Code.ensure_loaded?(mod), "#{inspect(mod)} (from row #{row.wire}) is not loaded"

        assert function_exported?(mod, :from_json, 1),
               "#{inspect(mod)} (from row #{row.wire}) does not export from_json/1"
      end
    end

    test "no wire method is duplicated across rows" do
      wires = Enum.map(MethodTable.rows(), & &1.wire)
      assert Enum.uniq(wires) |> length() == length(wires)
    end

    test "notification rows have result: nil; request rows have result != nil" do
      for row <- MethodTable.rows() do
        case row.kind do
          :notification ->
            assert row.result == nil, "#{row.wire} notification should have result: nil"

          :request ->
            assert row.result != nil, "#{row.wire} request should have result != nil"
        end
      end
    end

    test "layer in [:protocol, :session_control] iff callback == nil" do
      for row <- MethodTable.rows() do
        if row.layer in [:protocol, :session_control] do
          assert row.callback == nil, "#{row.wire} (#{row.layer}) should have callback: nil"
        else
          assert row.callback != nil, "#{row.wire} (:app) should have a callback"
        end
      end
    end

    test "params: nil only appears on logout, and only as a :request row" do
      nil_params_rows = Enum.filter(MethodTable.rows(), &(&1.params == nil))
      assert Enum.map(nil_params_rows, & &1.wire) == ["logout"]
      assert hd(nil_params_rows).kind == :request
    end
  end

  # -- §2.1 / D1-7: rows_for_side/1 --------------------------------------------

  describe "rows_for_side/1" do
    test ":agent sees client_to_agent + both" do
      wires = MethodTable.rows_for_side(:agent) |> MapSet.new(& &1.wire)
      assert "session/prompt" in wires
      assert "$/cancel_request" in wires
      refute "fs/read_text_file" in wires
    end

    test ":client sees agent_to_client + both" do
      wires = MethodTable.rows_for_side(:client) |> MapSet.new(& &1.wire)
      assert "fs/read_text_file" in wires
      assert "$/cancel_request" in wires
      refute "session/prompt" in wires
    end

    test "rows_for_side/1 never drops a :both row from either side" do
      both_wires = MethodTable.rows(:both) |> MapSet.new(& &1.wire)
      agent_wires = MethodTable.rows_for_side(:agent) |> MapSet.new(& &1.wire)
      client_wires = MethodTable.rows_for_side(:client) |> MapSet.new(& &1.wire)

      assert MapSet.subset?(both_wires, agent_wires)
      assert MapSet.subset?(both_wires, client_wires)
    end
  end

  # -- §1.1 compile-time invariants: fixtures via Code.compile_string ---------

  describe "compile-time invariants" do
    test "duplicate {direction, wire} raises CompileError" do
      assert_raise CompileError, ~r/invariant 1/, fn ->
        compile_fixture(:duplicate_direction_wire)
      end
    end

    test "notification with non-nil result raises CompileError" do
      assert_raise CompileError, ~r/invariant 2/, fn ->
        compile_fixture(:notification_with_result)
      end
    end

    test "request with nil result raises CompileError" do
      assert_raise CompileError, ~r/invariant 2/, fn ->
        compile_fixture(:request_without_result)
      end
    end

    test "duplicate callback atom on the same handling side raises CompileError" do
      assert_raise CompileError, ~r/invariant 3/, fn ->
        compile_fixture(:duplicate_callback)
      end
    end

    test "layer: :protocol row with a non-nil callback raises CompileError" do
      assert_raise CompileError, ~r/invariant 4/, fn ->
        compile_fixture(:protocol_with_callback)
      end
    end

    test "layer: :session_control row with a non-nil callback raises CompileError" do
      assert_raise CompileError, ~r/invariant 4/, fn ->
        compile_fixture(:session_control_with_callback)
      end
    end

    test "layer: :app row with a nil callback raises CompileError" do
      assert_raise CompileError, ~r/invariant 4/, fn ->
        compile_fixture(:app_without_callback)
      end
    end

    test "core row (ext: nil) starting with underscore raises CompileError" do
      assert_raise CompileError, ~r/invariant 5/, fn ->
        compile_fixture(:core_row_underscore_prefix)
      end
    end

    test "ext: :raxol row not starting with _raxol/ raises CompileError" do
      assert_raise CompileError, ~r/invariant 5/, fn ->
        compile_fixture(:raxol_row_bad_prefix)
      end
    end

    test "$/ prefix on a non-protocol layer raises CompileError" do
      assert_raise CompileError, ~r/invariant 5/, fn ->
        compile_fixture(:dollar_prefix_not_protocol)
      end
    end

    test "a well-formed minimal table compiles cleanly" do
      # No assert_raise: a well-formed fixture must compile without raising
      # at all. If Code.compile_string/1 raises here, the test itself fails
      # (ExUnit surfaces the exception), which is the assertion.
      assert [{_mod, _binary}] = compile_fixture(:well_formed)
    end
  end

  # -- §8.3: no-atom-creation property ------------------------------------------

  describe "no atom creation on unknown methods" do
    test "decoding 10k random unknown method binaries never creates a new atom" do
      alias Raxol.AgentClientProtocol.Router

      random_methods =
        for _ <- 1..10_000 do
          "unknown/" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
        end

      before_count = :erlang.system_info(:atom_count)

      Enum.each(random_methods, fn method ->
        assert Router.decode(:agent, :request, method, %{}) == {:error, :method_not_found}
        assert Router.decode(:client, :notification, method, %{}) == {:error, :method_not_found}
      end)

      after_count = :erlang.system_info(:atom_count)

      # Allow a small delta for anything incidental to the test process
      # itself (e.g. lazily-loaded modules) -- the point is that 10k
      # distinct unknown method strings do NOT create ~10k new atoms.
      assert after_count - before_count < 50,
             "atom count grew by #{after_count - before_count} after 10k unknown methods"
    end

    test "ext (\"_\"-prefixed) methods stay binaries end-to-end, never atomized" do
      alias Raxol.AgentClientProtocol.Router

      random_ext_methods =
        for _ <- 1..1_000 do
          "_vendor/" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
        end

      before_count = :erlang.system_info(:atom_count)

      results =
        Enum.map(random_ext_methods, fn method ->
          Router.decode(:agent, :request, method, %{"x" => 1})
        end)

      after_count = :erlang.system_info(:atom_count)

      assert Enum.all?(results, fn
               {:ok, {:ext_request, wire, %{"x" => 1}}} -> is_binary(wire)
               _ -> false
             end)

      assert after_count - before_count < 50
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp read_meta! do
    @meta_path |> File.read!() |> Jason.decode!()
  end

  # Each fixture defines a standalone module (unique name per test run, so
  # repeated `mix test` invocations / test retries don't collide on a
  # previously-defined module) with a MINIMAL two-row @rows table and the
  # same invariant-checking body as MethodTable, isolated from the real
  # table so these tests exercise the *mechanism*, not the real 23-row data.
  defp compile_fixture(name) do
    mod_name =
      "Raxol.AgentClientProtocol.MethodTableTest.Fixture#{System.unique_integer([:positive])}"

    source = """
    defmodule #{mod_name} do
      @rows #{fixture_rows(name)}

      duplicate_direction_wire =
        @rows
        |> Enum.frequencies_by(&{&1.direction, &1.wire})
        |> Enum.filter(fn {_key, count} -> count > 1 end)
        |> Enum.map(&elem(&1, 0))

      if duplicate_direction_wire != [] do
        raise CompileError, description: "invariant 1 violated: \#{inspect(duplicate_direction_wire)}"
      end

      bad_result_arity =
        Enum.filter(@rows, fn
          %{kind: :notification, result: result} -> result != nil
          %{kind: :request, result: result} -> result == nil
        end)

      if bad_result_arity != [] do
        raise CompileError, description: "invariant 2 violated: \#{inspect(Enum.map(bad_result_arity, & &1.wire))}"
      end

      agent_handling_rows = Enum.filter(@rows, &(&1.direction in [:client_to_agent, :both]))
      client_handling_rows = Enum.filter(@rows, &(&1.direction in [:agent_to_client, :both]))

      duplicate_callbacks = fn side_rows ->
        side_rows
        |> Enum.map(& &1.callback)
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies()
        |> Enum.filter(fn {_cb, count} -> count > 1 end)
        |> Enum.map(&elem(&1, 0))
      end

      dup_agent = duplicate_callbacks.(agent_handling_rows)
      dup_client = duplicate_callbacks.(client_handling_rows)

      if dup_agent != [] or dup_client != [] do
        raise CompileError, description: "invariant 3 violated: agent=\#{inspect(dup_agent)} client=\#{inspect(dup_client)}"
      end

      bad_layer_callback =
        Enum.filter(@rows, fn row ->
          case row.layer do
            layer when layer in [:protocol, :session_control] -> row.callback != nil
            :app -> row.callback == nil
          end
        end)

      if bad_layer_callback != [] do
        raise CompileError, description: "invariant 4 violated: \#{inspect(Enum.map(bad_layer_callback, & &1.wire))}"
      end

      bad_core = Enum.filter(@rows, fn row -> row.ext == nil and String.starts_with?(row.wire, "_") end)
      bad_raxol = Enum.filter(@rows, fn row -> row.ext == :raxol and not String.starts_with?(row.wire, "_raxol/") end)
      bad_dollar = Enum.filter(@rows, fn row -> String.starts_with?(row.wire, "\$/") and row.layer != :protocol end)

      if bad_core != [] or bad_raxol != [] or bad_dollar != [] do
        raise CompileError, description: "invariant 5 violated: \#{inspect({bad_core, bad_raxol, bad_dollar})}"
      end

      def rows, do: @rows
    end
    """

    Code.compile_string(source)
  end

  defp fixture_row(overrides) do
    base = %{
      wire: "some/method",
      direction: :client_to_agent,
      kind: :request,
      callback: :some_method,
      params: nil,
      result: Kernel,
      capability: nil,
      layer: :app,
      ext: nil
    }

    Map.merge(base, overrides) |> inspect()
  end

  defp fixture_rows(:duplicate_direction_wire) do
    "[" <>
      fixture_row(%{wire: "dup", callback: :a}) <>
      "," <>
      fixture_row(%{wire: "dup", callback: :b}) <>
      "]"
  end

  defp fixture_rows(:notification_with_result) do
    "[" <> fixture_row(%{kind: :notification, result: Kernel, callback: :a}) <> "]"
  end

  defp fixture_rows(:request_without_result) do
    "[" <> fixture_row(%{kind: :request, result: nil, params: nil, callback: :a}) <> "]"
  end

  defp fixture_rows(:duplicate_callback) do
    "[" <>
      fixture_row(%{wire: "one", callback: :same}) <>
      "," <>
      fixture_row(%{wire: "two", callback: :same}) <>
      "]"
  end

  defp fixture_rows(:protocol_with_callback) do
    "[" <>
      fixture_row(%{
        wire: "$/x",
        layer: :protocol,
        callback: :oops,
        kind: :notification,
        result: nil
      }) <> "]"
  end

  defp fixture_rows(:session_control_with_callback) do
    "[" <>
      fixture_row(%{
        wire: "session/oops",
        layer: :session_control,
        callback: :oops,
        kind: :notification,
        result: nil
      }) <> "]"
  end

  defp fixture_rows(:app_without_callback) do
    "[" <> fixture_row(%{layer: :app, callback: nil}) <> "]"
  end

  defp fixture_rows(:core_row_underscore_prefix) do
    "[" <> fixture_row(%{wire: "_oops", ext: nil, callback: :a}) <> "]"
  end

  defp fixture_rows(:raxol_row_bad_prefix) do
    "[" <> fixture_row(%{wire: "not_prefixed", ext: :raxol, callback: :a}) <> "]"
  end

  defp fixture_rows(:dollar_prefix_not_protocol) do
    "[" <> fixture_row(%{wire: "$/oops", layer: :app, callback: :a}) <> "]"
  end

  defp fixture_rows(:well_formed) do
    "[" <>
      fixture_row(%{wire: "well/formed", callback: :well_formed}) <>
      "," <>
      fixture_row(%{
        wire: "$/protocol_thing",
        layer: :protocol,
        callback: nil,
        kind: :notification,
        result: nil,
        direction: :both
      }) <>
      "]"
  end
end
