defmodule Raxol.Console.InboundTest do
  # Not async: boots named Console runtimes.
  use ExUnit.Case, async: false

  alias Raxol.Console.{Boot, Inbound, RuntimeConfig}
  alias Raxol.Earn.Console.Package
  alias Raxol.Gateway.{Adapter.InMemory, Pairing, Route, SessionRouter}

  defp package do
    %Package{runtime: :raxol, soul_md: "# Bot\n\nHi.", agents_md: nil, tasks: [], skills: []}
  end

  defp boot(name, pairing_opts) do
    {:ok, rc} =
      RuntimeConfig.build(
        package(),
        [
          bundle_default_mcp: false,
          channels: [%{platform: :in_memory, adapter: InMemory, config: %{sink: self()}}]
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
      pairing = Inbound.pairing_name(:inb_empty)
      {:ok, code} = Pairing.request_code(pairing, "newcomer")
      {:ok, "newcomer"} = Pairing.confirm(pairing, code)

      assert :ok = Inbound.route(:inb_empty, route("newcomer"), %{text: "hi"})
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

    test "seeds allow-everyone for a named platform" do
      boot(:inb_allplat, pairing: [allow_platforms: [:in_memory]])

      assert :ok = Inbound.route(:inb_allplat, route("anyone"), %{text: "hi"})
      refute Inbound.authorized?(:inb_allplat, route("anyone", :discord))
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
