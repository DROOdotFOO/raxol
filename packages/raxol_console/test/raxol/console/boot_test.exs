defmodule Raxol.Console.BootTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Console.Package
  alias Raxol.Agent.Action.Dynamic
  alias Raxol.Agent.Scheduler
  alias Raxol.Console.{Boot, RuntimeConfig}
  alias Raxol.Gateway.Adapter.InMemory
  alias Raxol.Gateway.SessionRouter

  defp job(id, prompt, cron) do
    %{id: id, prompt: prompt, schedule: cron, skills: [], target: nil, enabled: true}
  end

  defp start_scheduler(name) do
    start_supervised!(
      {Scheduler,
       name: name,
       runner: fn _job -> {:ok, "ok"} end,
       deliver: fn _target, _out -> :ok end,
       dispatch: fn fire -> fire.() end}
    )

    name
  end

  defp ids(server), do: server |> Scheduler.list() |> Enum.map(& &1.id) |> Enum.sort()

  describe "reconcile_jobs/2" do
    test "creates the desired jobs on a fresh scheduler" do
      s = start_scheduler(:recon_fresh)

      report = Boot.reconcile_jobs(s, [job("a", "pa", "0 9 * * *"), job("b", "pb", "0 10 * * *")])

      assert report.created == ["a", "b"]
      assert report.updated == []
      assert report.removed == []
      assert ids(s) == ["a", "b"]
    end

    test "is idempotent: re-reconciling an unchanged set is a no-op" do
      s = start_scheduler(:recon_idem)
      jobs = [job("a", "pa", "0 9 * * *")]

      Boot.reconcile_jobs(s, jobs)
      report = Boot.reconcile_jobs(s, jobs)

      assert report == %{created: [], updated: [], removed: [], failed: []}
    end

    test "updates changed jobs, creates new, removes stale" do
      s = start_scheduler(:recon_converge)
      Boot.reconcile_jobs(s, [job("a", "pa", "0 9 * * *"), job("b", "pb", "0 10 * * *")])

      report =
        Boot.reconcile_jobs(s, [
          job("a", "pa-CHANGED", "0 9 * * *"),
          job("c", "pc", "0 11 * * *")
        ])

      assert report.created == ["c"]
      assert report.updated == ["a"]
      assert report.removed == ["b"]
      assert ids(s) == ["a", "c"]

      {:ok, a} = Scheduler.get(s, "a")
      assert a.prompt == "pa-CHANGED"
    end

    test "records a failing job op in :failed instead of crashing" do
      s = start_scheduler(:recon_fail)

      report =
        Boot.reconcile_jobs(s, [job("ok", "p", "0 9 * * *"), job("bad", "p", "not-a-schedule")])

      assert report.created == ["ok"]
      assert [{"bad", _reason}] = report.failed
      assert ids(s) == ["ok"]
    end
  end

  describe "start/2" do
    test "boots the supervisor and reconciles the runtime config's jobs" do
      pkg = %Package{
        runtime: :raxol,
        soul_md: "# Bot\n\nHi.",
        agents_md: nil,
        tasks: [
          %{name: "t1", description: "d", cron: "0 9 * * *", prompt: "p1"},
          %{name: "t2", description: "d", cron: "0 10 * * *", prompt: "p2"}
        ],
        skills: []
      }

      {:ok, rc} = RuntimeConfig.build(pkg, bundle_default_mcp: false)

      {:ok, report} =
        Boot.start(rc,
          name: :boot_sup,
          scheduler_name: :boot_sched,
          reconciler_name: :boot_recon,
          adapters: %{}
        )

      on_exit(fn ->
        try do
          Supervisor.stop(:boot_sup)
        catch
          :exit, _ -> :ok
        end
      end)

      assert report.jobs.created == ["t1", "t2"]
      assert ids(:boot_sched) == ["t1", "t2"]
    end

    test "boots the gateway channel: a chat turn runs the persona + tools and replies" do
      pid = self()

      tool = %Dynamic{
        name: "echo",
        description: "echo",
        input_schema: %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}},
        invoke: fn params, _ctx ->
          send(pid, {:tool_invoked, params})
          {:ok, %{"echoed" => Map.get(params, :q) || Map.get(params, "q")}}
        end
      }

      counter = start_supervised!({Agent, fn -> 0 end})

      tool_calls_fn = fn ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if n == 0,
          do: [%{"name" => "echo", "arguments" => %{"q" => "hi"}, "id" => "c1"}],
          else: nil
      end

      pkg = %Package{
        runtime: :raxol,
        soul_md: "# Bot\n\nHi.",
        agents_md: nil,
        tasks: [],
        skills: []
      }

      {:ok, rc} =
        RuntimeConfig.build(pkg,
          bundle_default_mcp: false,
          channels: [%{platform: :in_memory, adapter: InMemory, config: %{sink: pid}}],
          agent_opts: [
            backend: Raxol.Agent.Backend.Mock,
            backend_opts: [tool_calls_fn: tool_calls_fn, response: "final answer"]
          ]
        )

      {:ok, report} =
        Boot.start(rc,
          name: :console_gw,
          scheduler_name: :console_gw_sched,
          reconciler_name: :console_gw_recon,
          actions: [tool]
        )

      on_exit(fn ->
        try do
          Supervisor.stop(:console_gw)
        catch
          :exit, _ -> :ok
        end
      end)

      assert report.channels == [:in_memory]

      raw = %{
        platform: :in_memory,
        chat_type: :dm,
        chat_id: "c",
        user_id: "u",
        event: %{text: "hi"}
      }

      {:ok, route, event} = InMemory.normalize_event(raw)
      assert :ok = SessionRouter.route(:"console_gw.router", route, event)

      assert_receive {:tool_invoked, params}
      assert "hi" in Map.values(params)
      assert_receive {:gateway_sent, ^route, "final answer"}
    end
  end

  describe "mcp supervision" do
    test "supervises bundled servers under a dynamic supervisor, fail-open" do
      pkg = %Package{
        runtime: :raxol,
        soul_md: "# Bot\n\nHi.",
        agents_md: nil,
        tasks: [],
        skills: []
      }

      {:ok, rc} = RuntimeConfig.build(pkg, mcp_servers: [%{name: :fake, command: "noop"}])

      # A client that never starts: the server is skipped (fail-open) while the
      # dynamic supervisor stays up.
      {:ok, report} =
        Boot.start(rc,
          name: :mcp_dyn,
          scheduler_name: :mcp_dyn_sched,
          reconciler_name: :mcp_dyn_recon,
          mcp_start: fn _opts -> {:error, :unavailable} end
        )

      on_exit(fn ->
        stop(:mcp_dyn)
        stop(report.mcp_supervisor)
      end)

      assert is_pid(report.mcp_supervisor)
      assert Process.alive?(report.mcp_supervisor)
      assert report.mcp.tools == 0
      assert [{:fake, :unavailable}] = report.mcp.failed
    end

    test "the mcp supervisor is owned by the tree and torn down when it stops" do
      pkg = %Package{
        runtime: :raxol,
        soul_md: "# Bot\n\nHi.",
        agents_md: nil,
        tasks: [],
        skills: []
      }

      {:ok, rc} = RuntimeConfig.build(pkg, mcp_servers: [%{name: :fake, command: "noop"}])

      {:ok, report} =
        Boot.start(rc,
          name: :mcp_owned,
          scheduler_name: :mcp_owned_sched,
          reconciler_name: :mcp_owned_recon,
          mcp_start: fn _opts -> {:error, :unavailable} end
        )

      mcp_sup = report.mcp_supervisor
      ref = Process.monitor(mcp_sup)

      # It is a child of the root Console.Supervisor (adopted), not dangling.
      child_pids = for {_, pid, _, _} <- Supervisor.which_children(:mcp_owned), do: pid
      assert mcp_sup in child_pids

      # Stopping the runtime tree tears the MCP supervisor down with it.
      Supervisor.stop(:mcp_owned)
      assert_receive {:DOWN, ^ref, :process, ^mcp_sup, _}
      refute Process.alive?(mcp_sup)
    end

    test "no dynamic supervisor when the package bundles no servers" do
      pkg = %Package{
        runtime: :raxol,
        soul_md: "# Bot\n\nHi.",
        agents_md: nil,
        tasks: [],
        skills: []
      }

      {:ok, rc} = RuntimeConfig.build(pkg, bundle_default_mcp: false)

      {:ok, report} =
        Boot.start(rc, name: :mcp_none, scheduler_name: :mcp_none_s, reconciler_name: :mcp_none_r)

      on_exit(fn -> stop(:mcp_none) end)

      assert report.mcp_supervisor == nil
    end
  end

  describe "skills activation" do
    setup do
      root = Path.join(System.tmp_dir!(), "console_skills_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "skills/greet"))

      File.write!(Path.join(root, "skills/greet/SKILL.md"), """
      ---
      name: greet
      description: How to greet users warmly
      ---
      Always open with a friendly hello.
      """)

      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, skills_dir: Path.join(root, "skills")}
    end

    defp bot_package do
      %Package{runtime: :raxol, soul_md: "# Bot\n\nHi.", agents_md: nil, tasks: [], skills: []}
    end

    test "indexes the package's skills into a per-console store", %{skills_dir: skills_dir} do
      {:ok, rc} = RuntimeConfig.build(bot_package(), bundle_default_mcp: false)

      {:ok, report} =
        Boot.start(rc,
          name: :skills_sup,
          scheduler_name: :skills_sched,
          reconciler_name: :skills_recon,
          skills_dir: skills_dir
        )

      on_exit(fn -> stop(:skills_sup) end)

      assert report.skills == %{store: :"skills_sup.skills", count: 1}
      assert [%{name: "greet"}] = Raxol.Agent.Skills.Store.list(server: :"skills_sup.skills")
    end

    test "no store is started when the skills dir is absent" do
      {:ok, rc} = RuntimeConfig.build(bot_package(), bundle_default_mcp: false)

      {:ok, report} =
        Boot.start(rc,
          name: :skills_none,
          scheduler_name: :skills_none_sched,
          reconciler_name: :skills_none_recon,
          skills_dir: "/does/not/exist"
        )

      on_exit(fn -> stop(:skills_none) end)

      assert report.skills == %{store: nil, count: 0}
    end

    test "a chat turn views a package skill through the store", %{skills_dir: skills_dir} do
      pid = self()
      counter = start_supervised!({Agent, fn -> 0 end})

      tool_calls_fn = fn ->
        n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if n == 0,
          do: [%{"name" => "skill_view", "arguments" => %{"name" => "greet"}, "id" => "c1"}],
          else: nil
      end

      {:ok, rc} =
        RuntimeConfig.build(bot_package(),
          bundle_default_mcp: false,
          channels: [%{platform: :in_memory, adapter: InMemory, config: %{sink: pid}}],
          agent_opts: [
            backend: Raxol.Agent.Backend.Mock,
            backend_opts: [tool_calls_fn: tool_calls_fn, response: "greeted"]
          ]
        )

      {:ok, _report} =
        Boot.start(rc,
          name: :skills_gw,
          scheduler_name: :skills_gw_sched,
          reconciler_name: :skills_gw_recon,
          skills_dir: skills_dir
        )

      on_exit(fn -> stop(:skills_gw) end)

      raw = %{
        platform: :in_memory,
        chat_type: :dm,
        chat_id: "c",
        user_id: "u",
        event: %{text: "hi"}
      }

      {:ok, route, event} = InMemory.normalize_event(raw)
      assert :ok = SessionRouter.route(:"skills_gw.router", route, event)

      assert_receive {:gateway_sent, ^route, "greeted"}

      # The view Action reached the real store through context[:skills].
      assert {:ok, %{view_count: 1}} =
               Raxol.Agent.Skills.Store.usage("greet", server: :"skills_gw.skills")
    end
  end

  defp stop(name) do
    Supervisor.stop(name)
  catch
    :exit, _ -> :ok
  end
end
