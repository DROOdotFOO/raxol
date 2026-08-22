defmodule Raxol.Console.InboundTest do
  # Not async: boots named Console runtimes.
  use ExUnit.Case, async: false

  alias Raxol.Console.{Boot, Inbound, RuntimeConfig}
  alias Raxol.Earn.Console.Package
  alias Raxol.Gateway.{Adapter.InMemory, Pairing, Route, SessionRouter}

  defp package do
    %Package{runtime: :raxol, soul_md: "# Bot\n\nHi.", agents_md: nil, tasks: [], skills: []}
  end

  defp channel(platform), do: %{platform: platform, adapter: InMemory, config: %{sink: self()}}

  defp two_channels, do: [channel(:in_memory), channel(:in_memory_2)]

  defp boot(name, pairing_opts, channels \\ nil) do
    {:ok, rc} =
      RuntimeConfig.build(
        package(),
        [
          bundle_default_mcp: false,
          channels: channels || [channel(:in_memory)]
        ] ++ pairing_opts
      )

    {:ok, report} =
      Boot.start(rc, name: name, scheduler_name: :"#{name}_s", reconciler_name: :"#{name}_r")

    on_exit(fn ->
      try do
        Supervisor.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    report
  end

  defp route(user_id, platform \\ :in_memory) do
    Route.new(%{
      platform: platform,
      chat_type: :dm,
      chat_id: "c-#{user_id}",
      user_id: user_id
    })
  end

  describe "unconfigured deployments" do
    # The decision on #884: silence means allow, because Pairing's allowlists
    # boot empty and enforcing by default would deny every Console running
    # today. What silence must NOT mean is quiet -- so the posture is announced.
    test "allow, and say so loudly" do
      handler_id = "open-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:raxol_console, :pairing, :open],
        fn _e, _m, meta, pid -> send(pid, {:telemetry, meta}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          report = boot(:inb_open, [])
          assert report.pairing == :open
        end)

      assert log =~ "gateway authorization is OPEN and was not configured"
      assert log =~ "pairing:"

      assert_receive {:telemetry,
                      %{console: :inb_open, declared?: false, platforms: [:in_memory]}}

      assert :ok = Inbound.route(:inb_open, route("anyone"), %{text: "hi"})

      # Open is a real Pairing state, not a branch that skips the gate -- which
      # is what makes both postures share one code path through Inbound.route/3.
      assert :allow = Pairing.authorize(Inbound.pairing_name(:inb_open), route("anyone"))

      # ...and it is open only on a platform the deployment actually connected.
      assert :deny = Pairing.authorize(Inbound.pairing_name(:inb_open), route("x", :telegram))
      refute Inbound.authorized?(:inb_open, route("x", :telegram))
    end

    test "an explicit :open is not nagged about" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          report = boot(:inb_declared, pairing: :open)
          assert report.pairing == :open
        end)

      refute log =~ "was not configured"
      assert :ok = Inbound.route(:inb_declared, route("anyone"), %{text: "hi"})
    end
  end

  describe "enforcing deployments" do
    test "an empty list enforces with nothing seeded, so only DM pairing gets in" do
      report = boot(:inb_empty, pairing: [])
      assert report.pairing == :enforce

      assert {:error, :unauthorized} = Inbound.route(:inb_empty, route("stranger"), %{text: "hi"})

      # The runtime pairing flow is the way in, and it works on a live runtime.
      # The scope is bound to the code, so the grant lands on the platform it
      # was minted for and nowhere else.
      pairing = Inbound.pairing_name(:inb_empty)
      {:ok, code} = Pairing.request_code(pairing, "newcomer", {:platform, :in_memory})
      {:ok, "newcomer"} = Pairing.confirm(pairing, code)

      assert :ok = Inbound.route(:inb_empty, route("newcomer"), %{text: "hi"})
      refute Inbound.authorized?(:inb_empty, route("newcomer", :telegram))
    end

    # The bug in #884: the Pairing server ran, nothing consulted it, and an
    # unauthorized sender got a session anyway. A denial must reach neither the
    # router nor the operator's blind spot, so both are asserted here.
    test "seeds a global allowlist, and a denial starts no session and is announced" do
      boot(:inb_users, pairing: [allowed_users: ["alice"]])
      router = Inbound.router_name(:inb_users)
      handler_id = "denied-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:raxol_console, :inbound, :denied],
        fn _e, _m, meta, pid -> send(pid, {:telemetry, meta}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:error, :unauthorized} = Inbound.route(:inb_users, route("mallory"), %{text: "hi"})
      assert SessionRouter.session_count(router) == 0

      assert_receive {:telemetry,
                      %{console: :inb_users, platform: :in_memory, user_id: "mallory"}}

      assert :ok = Inbound.route(:inb_users, route("alice"), %{text: "hi"})
      assert SessionRouter.session_count(router) == 1
    end

    # Telegram ids are integers in the wire payload and stringified into the
    # Route, so an integer in config has to land in the same set the check reads.
    test "an integer user id configured as an integer still matches" do
      boot(:inb_int, pairing: [allowed_users: [12_345]])

      assert :ok = Inbound.route(:inb_int, route(12_345), %{text: "hi"})
      assert :ok = Inbound.route(:inb_int, route("12345"), %{text: "hi"})
      assert {:error, :unauthorized} = Inbound.route(:inb_int, route(999), %{text: "hi"})
    end

    test "seeds a per-platform allowlist that does not leak across platforms" do
      boot(:inb_plat, pairing: [platform_users: [in_memory: ["bob"]]])

      assert :ok = Inbound.route(:inb_plat, route("bob"), %{text: "hi"})
      refute Inbound.authorized?(:inb_plat, route("bob", :telegram))
    end

    # :allowed_users grants on every connected platform, which is what a
    # deployment with two channels has to mean on purpose rather than inherit.
    test "warns when a cross-platform allowlist meets more than one channel" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          boot(:inb_multi, [pairing: [allowed_users: ["alice"]]], two_channels())
        end)

      assert log =~ ":allowed_users grants 1 id(s) on ALL of"
      assert log =~ ":platform_users"
    end

    test "a single-channel deployment is not warned, since there is nothing to collide" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          boot(:inb_single, pairing: [allowed_users: ["alice"]])
        end)

      refute log =~ "grants 1 id(s) on ALL of"
    end

    test "a scoped allowlist is not warned about however many channels there are" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          boot(
            :inb_multi_scoped,
            [pairing: [platform_users: [in_memory: ["alice"]]]],
            two_channels()
          )
        end)

      refute log =~ "on ALL of"
    end

    test "seeds allow-everyone for a named platform" do
      boot(:inb_allplat, pairing: [allow_platforms: [:in_memory]])

      assert :ok = Inbound.route(:inb_allplat, route("anyone"), %{text: "hi"})
      refute Inbound.authorized?(:inb_allplat, route("anyone", :discord))
    end

    # A platform atom naming no connected channel grants nothing, which reads
    # exactly like configuring no allowlist at all. `known_keys/1` already
    # refuses that ambiguity one level up, where a typo'd `allowed_user:` is
    # rejected on the same grounds.
    test "a platform atom that matches no channel is named in the log" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          report = boot(:inb_typo, pairing: [allow_platforms: [:in_memry]])
          assert report.pairing == :enforce
        end)

      assert log =~ "pairing names [:in_memry]"
      assert log =~ "Connected: [:in_memory]"
    end

    test "a correctly named platform warns about nothing" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          boot(:inb_no_typo, pairing: [allow_platforms: [:in_memory]])
        end)

      refute log =~ "pairing names"
    end
  end

  # The gate is only a gate if it cannot be walked around. `route/3` is the
  # documented door; these prove the walls.
  describe "enforcement outside Inbound.route/3" do
    test "the router refuses a feed that calls SessionRouter directly" do
      boot(:inb_bypass, pairing: [allowed_users: ["alice"]])
      router = Inbound.router_name(:inb_bypass)

      assert {:error, :unauthorized} =
               SessionRouter.route(router, route("mallory"), %{text: "hi"})

      assert SessionRouter.session_count(router) == 0

      assert :ok = SessionRouter.route(router, route("alice"), %{text: "hi"})
      assert SessionRouter.session_count(router) == 1
    end

    # The posture is seeded into Pairing's own init, so a crash restores it.
    # Seeded by calls against the running server it would not: an :open Console
    # would start denying every message forever, and an enforcing one would
    # forget its allowlist -- both silently, both with report.pairing still
    # claiming the posture the boot announced.
    test "an open Console is still open after its Pairing server crashes" do
      boot(:inb_crash_open, [])
      assert Inbound.authorized?(:inb_crash_open, route("anyone"))

      restart_pairing(:inb_crash_open)

      assert Inbound.authorized?(:inb_crash_open, route("anyone"))
    end

    test "an enforcing Console keeps its allowlist after a Pairing crash" do
      boot(:inb_crash_enforce, pairing: [allowed_users: ["alice"]])
      assert Inbound.authorized?(:inb_crash_enforce, route("alice"))

      restart_pairing(:inb_crash_enforce)

      assert Inbound.authorized?(:inb_crash_enforce, route("alice"))
      refute Inbound.authorized?(:inb_crash_enforce, route("mallory"))
    end

    # The caller is the deployment's feed loop, pumping a batch it cannot replay.
    # An uncaught exit from the authorization call would take that loop down
    # mid-batch. A Pairing that cannot answer denies -- it does not raise, and it
    # does not fall through to the router.
    test "a Pairing server that cannot answer denies instead of exiting the caller" do
      unbooted = :inb_no_such_console

      assert Process.whereis(Inbound.pairing_name(unbooted)) == nil

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          refute Inbound.authorized?(unbooted, route("anyone"))

          assert {:error, :unauthorized} =
                   Inbound.route(unbooted, route("anyone"), %{text: "hi"})
        end)

      assert log =~ "pairing server unreachable, denying"
    end

    # A route the adapter built from wire input, which Route.new/1 does not
    # validate. This used to crash the Pairing server -- and Pairing is the first
    # :rest_for_one child, so it took every live session with it.
    test "a malformed user id denies and leaves the runtime standing" do
      boot(:inb_malformed, pairing: [allowed_users: ["alice"]])
      pairing = Process.whereis(Inbound.pairing_name(:inb_malformed))

      bad = Route.new(%{platform: :in_memory, chat_type: :dm, chat_id: "c", user_id: %{"a" => 1}})

      assert {:error, :unauthorized} = Inbound.route(:inb_malformed, bad, %{text: "hi"})
      assert Process.alive?(pairing)
      assert SessionRouter.session_count(Inbound.router_name(:inb_malformed)) == 0
      assert :ok = Inbound.route(:inb_malformed, route("alice"), %{text: "hi"})
    end
  end

  defp restart_pairing(console) do
    name = Inbound.pairing_name(console)
    pid = Process.whereis(name)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    wait_for(name)
  end

  defp wait_for(name, attempts \\ 200)
  defp wait_for(name, 0), do: flunk("#{name} never came back")

  defp wait_for(name, attempts) do
    case Process.whereis(name) do
      nil ->
        Process.sleep(10)
        wait_for(name, attempts - 1)

      pid ->
        pid
    end
  end

  describe "headless runtimes" do
    test "connect no channels, so there is no gateway to authorize and no warning" do
      {:ok, rc} = RuntimeConfig.build(package(), bundle_default_mcp: false)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, report} =
            Boot.start(rc,
              name: :inb_headless,
              scheduler_name: :inb_headless_s,
              reconciler_name: :inb_headless_r
            )

          assert report.pairing == :none
          assert report.channels == []
        end)

      on_exit(fn ->
        try do
          Supervisor.stop(:inb_headless)
        catch
          :exit, _ -> :ok
        end
      end)

      refute log =~ "was not configured"
    end
  end
end
