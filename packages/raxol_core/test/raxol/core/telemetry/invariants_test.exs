defmodule Raxol.Core.Telemetry.InvariantsFixtureRegistry do
  @moduledoc false
  use Raxol.Core.Telemetry.Invariants,
    events: %{
      [:raxol, :core, :fixture, :impossible] => :invariant,
      [:raxol, :core, :fixture, :peer_frame] => :peer,
      [:raxol, :core, :fixture, :cache_hit] => :operational
    },
    dynamic: [
      [:raxol, :core, :fixture, :queue],
      {[:raxol, :core, :fixture, :inbound], :peer}
    ]
end

defmodule Raxol.Core.Telemetry.InvariantsTest do
  @moduledoc """
  Covers the two halves of the registry mechanism: the compile-time validation
  that stops a malformed or unenforceable declaration from ever compiling, and
  `scan_lib!/1`, whose exclusions are what keep a per-package completeness test
  worth running.
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Telemetry.Invariants
  alias Raxol.Core.Telemetry.InvariantsFixtureRegistry, as: Fixture

  describe "injected registry functions" do
    test "events/0 returns every declared static event with its classification" do
      assert Fixture.events() == %{
               [:raxol, :core, :fixture, :impossible] => :invariant,
               [:raxol, :core, :fixture, :peer_frame] => :peer,
               [:raxol, :core, :fixture, :cache_hit] => :operational
             }
    end

    test "invariant_events/0 is exactly the :invariant subset, sorted" do
      assert Fixture.invariant_events() == [[:raxol, :core, :fixture, :impossible]]
    end

    test "dynamic_families/0 lists both bare and classified families, sorted" do
      assert Fixture.dynamic_families() == [
               [:raxol, :core, :fixture, :inbound],
               [:raxol, :core, :fixture, :queue]
             ]
    end

    test "classification/1 resolves exact events, dynamic members, and unknowns" do
      assert Fixture.classification([:raxol, :core, :fixture, :impossible]) == :invariant
      assert Fixture.classification([:raxol, :core, :fixture, :peer_frame]) == :peer

      # A runtime-suffixed member of a family inherits the family's verdict.
      assert Fixture.classification([:raxol, :core, :fixture, :queue, :settle]) == :operational
      assert Fixture.classification([:raxol, :core, :fixture, :inbound, :frame]) == :peer

      assert Fixture.classification([:raxol, :core, :fixture, :never_declared]) == nil
    end
  end

  describe "compile-time validation" do
    test "an unknown classification is rejected" do
      error =
        assert_raise ArgumentError, fn ->
          compile_registry("""
          events: %{[:raxol, :core, :bad, :event] => :probably_fine}
          """)
        end

      assert error.message =~ "is classified"
      assert error.message =~ ":probably_fine"
      assert error.message =~ "[:invariant, :peer, :operational]"
    end

    test "an event name that is not a non-empty list of atoms is rejected" do
      assert_raise ArgumentError, ~r/is not a telemetry\nevent name/, fn ->
        compile_registry(~S|events: %{"raxol.core.bad" => :operational}|)
      end

      assert_raise ArgumentError, ~r/is not a telemetry\nevent name/, fn ->
        compile_registry("events: %{[] => :operational}")
      end
    end

    test "a duplicate event key is rejected rather than silently overridden" do
      error =
        assert_raise ArgumentError, fn ->
          compile_registry("""
          events: %{
            [:raxol, :core, :dup] => :operational,
            [:raxol, :core, :dup] => :peer
          }
          """)
        end

      assert error.message =~ "duplicate event key"
      assert error.message =~ "[:raxol, :core, :dup]"
    end

    test "a dynamic family classified :invariant is rejected" do
      error =
        assert_raise ArgumentError, fn ->
          compile_registry("""
          events: %{[:raxol, :core, :fine] => :operational},
          dynamic: [{[:raxol, :core, :queue], :invariant}]
          """)
        end

      assert error.message =~ "cannot be\n:invariant"
      assert error.message =~ "cannot spell the name"
    end

    test "a dynamic family that is also a static key is rejected" do
      error =
        assert_raise ArgumentError, fn ->
          compile_registry("""
          events: %{[:raxol, :core, :queue] => :operational},
          dynamic: [[:raxol, :core, :queue]]
          """)
        end

      assert error.message =~ "appears in both `events:` and"
    end

    test "a computed events map is rejected, since it cannot be validated" do
      error =
        assert_raise ArgumentError, fn ->
          compile_registry("events: Enum.into([], %{})")
        end

      assert error.message =~ "must be a literal map"
    end

    test "a missing :events option is rejected" do
      assert_raise KeyError, fn -> compile_registry("dynamic: [[:raxol, :core, :queue]]") end
    end
  end

  describe "scan_lib!/1" do
    # ExUnit's :tmp_dir tag would leave an untracked packages/raxol_core/tmp/
    # behind, so the fixture tree goes to the system temp dir under a name
    # unique to this module and run: five agents share this machine.
    setup do
      lib =
        Path.join([
          System.tmp_dir!(),
          "raxol-core-invariants-scan-#{System.unique_integer([:positive])}",
          "lib"
        ])

      File.mkdir_p!(Path.join(lib, "nested"))
      File.write!(Path.join(lib, "emitter.ex"), emitter_fixture())
      File.write!(Path.join(lib, "nested/deep.ex"), nested_fixture())
      on_exit(fn -> File.rm_rf!(Path.dirname(lib)) end)

      {:ok, lib: lib, found: Invariants.scan_lib!(lib)}
    end

    test "finds emits through :telemetry, through wrappers, and through helpers", ctx do
      assert [:raxol, :core, :scanned, :direct] in ctx.found
      assert [:raxol, :core, :scanned, :wrapped] in ctx.found
      assert [:raxol, :core, :scanned, :spanned] in ctx.found
      assert [:raxol, :core, :scanned, :helper] in ctx.found
      assert [:raxol, :core, :scanned, :qualified_helper] in ctx.found
    end

    test "resolves an event name bound to a module attribute", ctx do
      assert [:raxol, :core, :scanned, :heartbeat] in ctx.found
    end

    test "descends into subdirectories", ctx do
      assert [:raxol, :core, :scanned, :nested] in ctx.found
    end

    test "ignores an event mentioned only in a moduledoc", ctx do
      refute [:raxol, :core, :scanned, :documented] in ctx.found
    end

    test "ignores an event mentioned only in a comment", ctx do
      refute [:raxol, :core, :scanned, :commented] in ctx.found
    end

    test "ignores an event that is only subscribed to via attach_many", ctx do
      refute [:raxol, :core, :scanned, :subscribed] in ctx.found
    end

    test "ignores a name whose final segment is computed at runtime", ctx do
      # This is the case `dynamic:` families exist for: there is no literal to
      # find, so a completeness test must not be able to demand one.
      refute Enum.any?(ctx.found, &List.starts_with?(&1, [:raxol, :core, :scanned, :queue]))
    end

    test "returns a sorted, deduplicated list", ctx do
      assert ctx.found == Enum.sort(Enum.uniq(ctx.found))
      assert Enum.count(ctx.found, &(&1 == [:raxol, :core, :scanned, :direct])) == 1
    end

    test "raises when the lib path does not exist, so a moved tree fails loudly", ctx do
      missing = Path.join(ctx.lib, "gone")

      assert_raise ArgumentError, ~r/is not a directory/, fn -> Invariants.scan_lib!(missing) end
    end

    test "raises when the directory holds no source, instead of scanning nothing", ctx do
      empty = Path.join(ctx.lib, "empty")
      File.mkdir_p!(empty)

      assert_raise ArgumentError, ~r/no \.ex files under/, fn -> Invariants.scan_lib!(empty) end
    end
  end

  # -- fixtures ---------------------------------------------------------------

  defp compile_registry(opts) do
    module = "RaxolCoreInvariantsCompileFixture#{System.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{module} do
      use Raxol.Core.Telemetry.Invariants, #{opts}
    end
    """)
  end

  defp emitter_fixture do
    ~S'''
    defmodule Scanned.Emitter do
      @moduledoc """
      Emits telemetry. Also documents [:raxol, :core, :scanned, :documented],
      which nothing emits: prose is not an emit site.
      """

      # A retired event, [:raxol, :core, :scanned, :commented], kept only as a
      # note. A comment is not an emit site either.

      @heartbeat [:raxol, :core, :scanned, :heartbeat]

      def direct do
        :telemetry.execute([:raxol, :core, :scanned, :direct], %{count: 1}, %{})
      end

      def wrapped do
        Context.execute([:raxol, :core, :scanned, :wrapped], %{}, %{})
      end

      def spanned(fun) do
        Telemetry.span([:raxol, :core, :scanned, :spanned], %{}, fun)
      end

      def helper do
        emit_telemetry([:raxol, :core, :scanned, :helper], %{})
      end

      def qualified_helper do
        Other.emit_event([:raxol, :core, :scanned, :qualified_helper], %{})
      end

      def heartbeat do
        :telemetry.execute(@heartbeat, %{}, %{})
      end

      def queue(suffix) do
        :telemetry.execute([:raxol, :core, :scanned, :queue, suffix], %{}, %{})
      end

      def subscribe do
        :telemetry.attach_many(
          :scanned_fixture,
          [[:raxol, :core, :scanned, :subscribed]],
          &__MODULE__.noop/4,
          nil
        )
      end

      def noop(_event, _measurements, _metadata, _config), do: :ok
    end
    '''
  end

  defp nested_fixture do
    ~S'''
    defmodule Scanned.Nested do
      @moduledoc false
      def emit do
        :telemetry.execute([:raxol, :core, :scanned, :nested], %{}, %{})
      end
    end
    '''
  end
end
