defmodule Raxol.PackageBoundariesTest do
  @moduledoc """
  `scripts/check_package_boundaries.exs` over fixture trees: each way a
  runtime-side file can name agent-side code fails the check on its own, and
  each exemption passes it.

  Every case is the base tree plus one file. The base tree has a root
  defining its own `Raxol.CLI` modules, two runtime packages (`raxol_core`,
  and `raxol_journal` defining the exempt modules) and two agent packages
  (`raxol_agent`, `raxol_cli`). The checker boots a VM per tree, so the trees
  are checked concurrently, once.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/check_package_boundaries.exs", __DIR__)

  @journal_modules ~w(
    Raxol.Agent.Contract
    Raxol.Agent.Contract.Event
    Raxol.Agent.Journal
    Raxol.Agent.Journal.Chain
    Raxol.Agent.Journal.FileStore
    Raxol.Agent.Journal.FileStore.Reader
    Raxol.Agent.Journal.FileStore.Writer
    Raxol.Agent.Journal.Records.Checkpoint
    Raxol.Agent.Journal.Records.Checkpoint.FileBackend
    Raxol.Agent.Journal.Tip
  )

  @root_cli_modules ~w(
    Raxol.CLI.Colors
    Raxol.CLI.ErrorDisplay
    Raxol.CLI.ErrorFormatter
    Raxol.CLI.Spinner
  )

  # {label, file, source, reported name, reported kind}
  @crossings [
    {"a remote call", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: Raxol.Agent.Session.start()
     end
     """, "Raxol.Agent.Session", "call"},
    {"a call through an alias", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       alias Raxol.Payments.Ledger
       def f, do: Ledger.total()
     end
     """, "Raxol.Payments.Ledger", "alias, call"},
    {"an alias nothing in the file uses", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       defmacro __using__(_opts) do
         quote do
           alias Raxol.Agent.Session
         end
       end
     end
     """, "Raxol.Agent.Session", "alias"},
    {"a multi-alias nothing in the file uses", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       alias Raxol.Payments.{Ledger, Wallet}
     end
     """, "Raxol.Payments.Wallet", "alias"},
    {"Module.concat under a literal agent namespace", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f(name),
         do: Module.concat(Raxol.Agent.Actions, Macro.camelize(name))
     end
     """, "Raxol.Agent.Actions", "prefix"},
    {"Module.safe_concat under an aliased agent namespace",
     "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       alias Raxol.Earn, as: Sellers
       def f(name), do: Module.safe_concat(Sellers, name)
     end
     """, "Raxol.Earn", "alias, prefix"},
    {"a capture", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: &Raxol.Earn.Seller.run/1
     end
     """, "Raxol.Earn.Seller", "call"},
    {"apply/3", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: apply(Raxol.Broker.Executor, :run, [])
     end
     """, "Raxol.Broker.Executor", "apply"},
    {"a module atom", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: :"Elixir.Raxol.Earn.Seller"
     end
     """, "Raxol.Earn.Seller", "atom"},
    {"a string that names a module", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f(lookup), do: lookup.("Raxol.Web3.Router")
     end
     """, "Raxol.Web3.Router", "string"},
    {"a string with the Elixir prefix", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: String.to_existing_atom("Elixir.Raxol.Console.Boot")
     end
     """, "Raxol.Console.Boot", "atom, string"},
    {"a module name inside prose in a string", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: raise("start Raxol.Agent.Supervisor first")
     end
     """, "Raxol.Agent.Supervisor", "string"},
    {"a word sigil", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: ~w(Raxol.Agent.Team Raxol.Core.Thing)
     end
     """, "Raxol.Agent.Team", "string"},
    {"a regex over module names", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f(name), do: name =~ ~r/^Raxol\.Payments\./
     end
     """, "Raxol.Payments", "string"},
    {"a process name", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: GenServer.whereis(Raxol.Agent.Registry)
     end
     """, "Raxol.Agent.Registry", "value"},
    {"a process name spelled as a plain atom", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: Process.whereis(:"Raxol.Agent.Registry")
     end
     """, "Raxol.Agent.Registry", "name"},
    {"@compile no_warn_undefined", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       @compile {:no_warn_undefined, [Raxol.Agent.Stream]}
     end
     """, "Raxol.Agent.Stream", "compile"},
    {"a Code.ensure_loaded? guard", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: Code.ensure_loaded?(Raxol.Agent.Supervisor)
     end
     """, "Raxol.Agent.Supervisor", "value"},
    {"a child spec", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def children, do: [{Raxol.Agent.Supervisor, []}]
     end
     """, "Raxol.Agent.Supervisor", "value"},
    {"@behaviour", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       @behaviour Raxol.Agent.Action
     end
     """, "Raxol.Agent.Action", "directive"},
    {"use of the bare namespace", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       use Raxol.Agent
     end
     """, "Raxol.Agent", "directive"},
    {"a typespec", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       @spec f() :: Raxol.Agent.Session.t()
       def f, do: nil
     end
     """, "Raxol.Agent.Session", "typespec"},
    {"a struct", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: %Raxol.Payments.Ledger{}
     end
     """, "Raxol.Payments.Ledger", "value"},
    {"a literal Module.concat", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: Module.concat(Raxol.Agent, Session)
     end
     """, "Raxol.Agent.Session", "concat"},
    {"code interpolated into a doc", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       @moduledoc "Wraps #{inspect(Raxol.Agent.Session)}."
     end
     """, "Raxol.Agent.Session", "value"},
    {"the protocol package's namespace", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: Raxol.AgentClientProtocol.Client.start()
     end
     """, "Raxol.AgentClientProtocol.Client", "call"},
    {"an agent application's own namespace", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: Process.whereis(RaxolAgent.Supervisor)
     end
     """, "RaxolAgent.Supervisor", "value"},
    {"the gateway's agent handler, by exact name", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: {Raxol.Gateway.Handler.Agent, []}
     end
     """, "Raxol.Gateway.Handler.Agent", "value"},
    {"the agent bridge, by exact name", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: Raxol.MCP.AgentBridge.actions_to_mcp_tools([])
     end
     """, "Raxol.MCP.AgentBridge", "call"},
    {"a Raxol.CLI module the root does not define", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: Raxol.CLI.MCP.authorize(nil)
     end
     """, "Raxol.CLI.MCP", "call"},
    {"a protocol implementation for an agent module", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f(secret, opts), do: Inspect.Raxol.Payments.Secret.inspect(secret, opts)
     end
     """, "Inspect.Raxol.Payments.Secret", "call"},
    {"an agent Mix task under an application namespace",
     "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: Mix.Tasks.RaxolEarn.Order.run([])
     end
     """, "Mix.Tasks.RaxolEarn.Order", "call"},
    {"an agent Mix task, by exact name", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: Mix.Tasks.Raxol.Docs.Tools.run([])
     end
     """, "Mix.Tasks.Raxol.Docs.Tools", "call"},
    {"a module under an exempt one that raxol_journal does not define",
     "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: Raxol.Agent.Journal.Compactor.run()
     end
     """, "Raxol.Agent.Journal.Compactor", "call"},
    {"a name that only starts like an exempt one", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: Raxol.Agent.JournalIndex.build()
     end
     """, "Raxol.Agent.JournalIndex", "call"},
    {"an agent application atom", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: Application.get_env(:raxol_agent, :mcp_tools)
     end
     """, "raxol_agent", "app"},
    {"a module reference in the release catalog",
     "lib/raxol/release/package_check.ex",
     ~S"""
     defmodule Raxol.Release.PackageCheck do
       def f, do: Raxol.Agent.Session.start()
     end
     """, "Raxol.Agent.Session", "call"},
    {"an agent application outside the release catalog's rows",
     "lib/raxol/release/package_check.ex",
     ~S"""
     defmodule Raxol.Release.PackageCheck do
       @packages [%{app: :raxol_agent, path: "packages/raxol_agent"}]
       def packages, do: @packages
       def f, do: Application.get_env(:raxol_payments, :x)
     end
     """, "raxol_payments", "app"},
    {"a release catalog row whose path is another directory",
     "lib/raxol/release/package_check.ex",
     ~S"""
     defmodule Raxol.Release.PackageCheck do
       @packages [
         %{app: :raxol_agent, path: "packages/raxol_agent"},
         %{app: :raxol_cli, path: "packages/raxol_core"}
       ]
       def packages, do: @packages
     end
     """, "raxol_cli", "app"},
    {"a runtime package's lib",
     "packages/raxol_core/lib/raxol/core/crossing.ex",
     ~S"""
     defmodule Raxol.Core.Crossing do
       def f, do: Raxol.Agent.Session.start()
     end
     """, "Raxol.Agent.Session", "call"},
    {"a guarded call in root config", "config/runtime.exs",
     ~S"""
     import Config

     if Code.ensure_loaded?(Raxol.Payments.Accounting) do
       Raxol.Payments.Accounting.env_config()
     end
     """, "Raxol.Payments.Accounting", "call, value"},
    {"an agent application configured in root config", "config/runtime.exs",
     ~S"""
     import Config
     config :raxol_payments, :accounting, []
     """, "raxol_payments", "app"},
    {"an agent application configured in a runtime package's config",
     "packages/raxol_core/config/config.exs",
     ~S"""
     import Config
     config :raxol_earn, accounting_enabled: false
     """, "raxol_earn", "app"},
    {"a dependency in a runtime package's mix.exs",
     "packages/raxol_core/mix.exs",
     ~S"""
     defmodule RaxolCore.MixProject do
       use Mix.Project
       def project, do: [app: :raxol_core, version: "0.1.0", deps: deps()]
       defp deps, do: [{:raxol_agent, path: "../raxol_agent"}]
     end
     """, "raxol_agent", "app"},
    {"an optional dependency behind a helper", "packages/raxol_core/mix.exs",
     ~S"""
     defmodule RaxolCore.MixProject do
       use Mix.Project
       def project, do: [app: :raxol_core, version: "0.1.0", deps: deps()]

       defp deps,
         do: [raxol_dep(:raxol_agent, "~> 2.7", "../raxol_agent", optional: true)]

       defp raxol_dep(name, version, path, opts),
         do: {name, version, [path: path] ++ opts}
     end
     """, "raxol_agent", "app"},
    {"a test-only dependency", "packages/raxol_core/mix.exs",
     ~S"""
     defmodule RaxolCore.MixProject do
       use Mix.Project
       def project, do: [app: :raxol_core, version: "0.1.0", deps: deps()]
       defp deps, do: [{:raxol_payments, "~> 0.1", only: :test}]
     end
     """, "raxol_payments", "app"},
    {"a dependency in the root mix.exs", "mix.exs",
     ~S"""
     defmodule Raxol.MixProject do
       use Mix.Project
       def project, do: [app: :raxol, version: "0.1.0", deps: deps()]

       defp deps,
         do: [
           {:raxol_core, path: "packages/raxol_core"},
           {:raxol_cli, path: "packages/raxol_cli"}
         ]
     end
     """, "raxol_cli", "app"},
    {"a module named in the root mix.exs", "mix.exs",
     ~S"""
     defmodule Raxol.MixProject do
       use Mix.Project

       def project,
         do: [
           app: :raxol,
           version: "0.1.0",
           deps: [{:raxol_core, path: "packages/raxol_core"}],
           docs: [nest_modules_by_prefix: [Raxol.Core, Raxol.Agent]]
         ]
     end
     """, "Raxol.Agent", "value"},
    {"application atoms in a word sigil", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: Enum.each(~w(raxol_agent raxol_payments)a, &Application.load/1)
     end
     """, "raxol_payments", "app"},
    {"an application atom made from a string", "lib/raxol/crossing.ex",
     ~S"""
     defmodule Raxol.Crossing do
       def f, do: Application.ensure_all_started(String.to_atom("raxol_agent"))
     end
     """, "raxol_agent", "app"},
    {"dependencies built from a word sigil", "packages/raxol_core/mix.exs",
     ~S"""
     defmodule RaxolCore.MixProject do
       use Mix.Project
       def project, do: [app: :raxol_core, version: "0.1.0", deps: deps()]

       defp deps do
         for app <- ~w(raxol_agent raxol_payments)a,
             do: {app, path: "../#{app}", optional: true}
       end
     end
     """, "raxol_agent", "app"},
    {"a dependency whose atom is made from a string",
     "packages/raxol_core/mix.exs",
     ~S"""
     defmodule RaxolCore.MixProject do
       use Mix.Project
       def project, do: [app: :raxol_core, version: "0.1.0", deps: deps()]

       defp deps do
         for name <- ["raxol_earn"],
             do: {String.to_atom(name), path: Path.join("..", name)}
       end
     end
     """, "raxol_earn", "app"},
    {"a template that calls an agent module",
     "packages/raxol_core/lib/raxol/core/page.html.heex",
     ~S"""
     <section>
       <%= Raxol.Agent.Session.info(@id) %>
     </section>
     """, "Raxol.Agent.Session", "string"},
    {"a generator template that depends on an agent application",
     "priv/templates/mix.exs.eex",
     ~S"""
     defp deps do
       [{:raxol, "~> 2.7"}, {:raxol_agent, "~> 2.7"}]
     end
     """, "raxol_agent", "app"},
    {"an Erlang source that calls an agent module",
     "packages/raxol_core/src/raxol_core_bridge.erl",
     ~S"""
     -module(raxol_core_bridge).
     -export([total/0]).
     total() -> 'Elixir.Raxol.Payments.Ledger':total().
     """, "Raxol.Payments.Ledger", "string"}
  ]

  # {label, file, source}
  @exemptions [
    {"the modules raxol_journal defines", "lib/raxol/exempt.ex",
     """
     defmodule Raxol.Exempt do
       def f, do: [#{Enum.join(@journal_modules, ", ")}]
       def g(event), do: Raxol.Agent.Contract.encode_line(event)
       def h, do: %Raxol.Agent.Contract.Event{}
     end
     """},
    {"a comment", "lib/raxol/exempt.ex",
     ~S"""
     defmodule Raxol.Exempt do
       # Raxol.Agent.Session owns the turn; `:raxol_agent` starts it.
       def f, do: nil
     end
     """},
    {"doc attributes", "lib/raxol/exempt.ex",
     ~S'''
     defmodule Raxol.Exempt do
       @moduledoc """
       The neutral half of `Raxol.Agent.EmitBridge`.

           struct(Raxol.Agent.Command, cmd)
       """

       @typedoc "What `Raxol.Payments.Ledger` books."
       @type t :: map()

       @doc ~S"""
       See `Raxol.Agent.Session`.
       """
       @doc deprecated: "Raxol.Earn.Seller replaces it"
       def f, do: nil

       @deprecated "Use Raxol.Web3.Router"
       def g, do: nil
     end
     '''},
    {"a Mix task's @shortdoc", "lib/mix/tasks/exempt.ex",
     ~S"""
     defmodule Mix.Tasks.Exempt do
       @shortdoc "Lists what Raxol.Agent.Session would run"
       def run(_argv), do: :ok
     end
     """},
    {"the root's own Raxol.CLI modules", "lib/raxol/exempt.ex",
     ~S"""
     defmodule Raxol.Exempt do
       def f, do: Raxol.CLI.Colors.red("x")
     end
     """},
    {"names that only resemble an agent namespace", "lib/raxol/exempt.ex",
     ~S"""
     defmodule Raxol.Exempt do
       def f, do: [Raxol.Agents.Roster, Raxol.Agentic, Raxol.PaymentsTable]
       def g, do: "Raxol.Agentless.Mode"
       def h, do: Raxol.Gateway.Handler.AgentLike
     end
     """},
    {"runtime application atoms", "lib/raxol/exempt.ex",
     ~S"""
     defmodule Raxol.Exempt do
       def f, do: Application.get_env(:raxol_core, :x)
       def g, do: Application.get_env(:raxol_gateway, :x)
     end
     """},
    {"application names that only resemble an agent one", "lib/raxol/exempt.ex",
     ~S"""
     defmodule Raxol.Exempt do
       def f, do: ~w(raxol_core raxol_agents raxol_clients my_raxol_cli)a
       def g, do: String.to_atom("raxol_earnings")
     end
     """},
    {"agent application atoms in the release catalog",
     "lib/raxol/release/package_check.ex",
     ~S"""
     defmodule Raxol.Release.PackageCheck do
       @packages [
         %{app: :raxol_core, path: "packages/raxol_core"},
         %{app: :raxol_agent, path: "packages/raxol_agent"},
         %{app: :raxol_cli, path: "packages/raxol_cli"}
       ]
       def packages, do: @packages
     end
     """},
    {"a template naming only the runtime side",
     "packages/raxol_core/lib/raxol/core/page.html.heex",
     ~S"""
     <%= Raxol.Core.Thing.render(@thing) %>
     <%= inspect(Raxol.Agent.Journal.Tip) %> raxol_core raxol_agents
     """},
    {"an agent package's template",
     "packages/raxol_cli/priv/templates/app.ex.eex",
     ~S"""
     use Raxol.Agent
     """},
    {"a root test", "test/raxol/crossing_test.exs",
     ~S"""
     defmodule Raxol.CrossingTest do
       def f, do: Raxol.Agent.Session.start()
     end
     """},
    {"a runtime package's test", "packages/raxol_core/test/crossing_test.exs",
     ~S"""
     defmodule Raxol.Core.CrossingTest do
       def f, do: Raxol.Agent.Session.start()
     end
     """},
    {"an agent package naming both sides",
     "packages/raxol_agent/lib/raxol/agent/free.ex",
     ~S"""
     defmodule Raxol.Agent.Free do
       def f, do: [Raxol.Core.Thing, Raxol.Agent.Session, Raxol.Agent.Journal]
       def g, do: Application.get_env(:raxol_payments, :accounting)
     end
     """},
    {"a protocol implementation for an exempt module",
     "packages/raxol_journal/lib/raxol/agent/journal/inspect.ex",
     ~S"""
     defimpl Inspect, for: Raxol.Agent.Journal.Tip do
       def inspect(_tip, _opts), do: "#Tip<>"
     end
     """},
    {"aliases and Module.concat prefixes on the runtime side",
     "lib/raxol/exempt.ex",
     ~S"""
     defmodule Raxol.Exempt do
       alias Raxol.Agent.Journal
       alias Raxol.Agent.{Contract, Journal.Tip}
       def f(name), do: Module.concat(Raxol.Core, name)
       def g(name), do: Module.concat(Journal, name)
     end
     """},
    {"an alias of an undeclared runtime module that nothing uses",
     "packages/raxol_core/lib/raxol/core/exempt.ex",
     ~S"""
     defmodule Raxol.Core.Exempt do
       alias Raxol.CLI.Colors
       def f(name), do: Module.concat(Raxol.Missing, name)
     end
     """}
  ]

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "raxol_boundaries_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)

    single_file =
      for {label, file, source, _name, _kind} <- @crossings do
        {label, [{file, source}]}
      end ++
        for {label, file, source} <- @exemptions do
          {label, [{file, source}]}
        end

    results =
      (single_file ++ structural_cases())
      |> Enum.with_index()
      |> Task.async_stream(
        fn {{label, files}, index} ->
          dir = Path.join(root, Integer.to_string(index))
          build(dir, files)
          {label, check(dir)}
        end,
        max_concurrency: 4,
        timeout: 120_000
      )
      |> Map.new(fn {:ok, result} -> result end)

    %{results: results}
  end

  describe "a runtime-side file naming agent-side code fails:" do
    for {label, file, _source, name, kind} <- @crossings do
      test label, %{results: results} do
        {output, status} = Map.fetch!(results, unquote(label))

        assert status == 1, output
        assert output =~ "runtime-side file names agent-side code"

        assert Enum.any?(
                 String.split(output, "\n"),
                 &Regex.match?(
                   ~r/^\s+#{Regex.escape(unquote(file))}:\d+\s+#{Regex.escape(unquote(name))}\s+\(#{Regex.escape(unquote(kind))}\)$/,
                   &1
                 )
               ),
               output
      end
    end
  end

  describe "exempt:" do
    for {label, _file, _source} <- @exemptions do
      test label, %{results: results} do
        {output, status} = Map.fetch!(results, unquote(label))

        assert status == 0, output
        assert output =~ "none across the runtime/agent line"
      end
    end
  end

  describe "the line itself:" do
    test "the base tree holds", %{results: results} do
      assert {output, 0} = results["base"]
      assert output =~ "OK: package boundaries hold (0 grandfathered"
    end

    test "a runtime tree may not define a module under an agent namespace",
         %{results: results} do
      assert {output, 1} = results["runtime defines an agent namespace"]

      assert output =~
               ~r/Raxol\.Agent\.Thing\s+defined in raxol_core, which is runtime-side/
    end

    test "a runtime tree may not define the agent handler or bridge",
         %{results: results} do
      assert {output, 1} = results["runtime defines an exact agent module"]

      assert output =~
               ~r/Raxol\.MCP\.AgentBridge\s+defined in raxol_core, which is runtime-side/
    end

    test "an exempt name must be defined by a runtime tree",
         %{results: results} do
      assert {output, 1} = results["exemption without a definition"]

      assert output =~
               ~r/Raxol\.Agent\.Journal\.Tip\s+exempt, but no runtime tree defines it/
    end

    test "an allowlist entry on one side of the line is kept",
         %{results: results} do
      assert {output, 0} = results["allowlist entry within the runtime side"]
      assert output =~ "(1 grandfathered"
    end

    test "an allowlist entry across the line fails", %{results: results} do
      assert {output, 1} = results["allowlist entry across the line"]
      assert output =~ "entries cross the runtime/agent line"

      assert output =~
               ~r/packages\/raxol_cli\/lib\/raxol\/cli\/mcp\.ex\s+Raxol\.Core\.Thing\traxol_core/
    end

    test "the release catalog's exemption fails once it is unused",
         %{results: results} do
      assert {output, 1} = results["release catalog without agent applications"]

      assert output =~
               "lib/raxol/release/package_check.ex has no row for an agent package"
    end

    test "a package on neither side stops the check", %{results: results} do
      assert {output, 2} = results["package on neither side"]

      assert output =~
               "packages/raxol_other is on neither side of the runtime/agent line"
    end

    test "a Raxol.CLI module is agent-side with no raxol_cli tree to own it",
         %{results: results} do
      assert {output, 1} = results["no raxol_cli tree"]

      assert output =~
               ~r/^\s+config\/config\.exs:2\s+Raxol\.CLI\.MCP\s+\(value\)$/m
    end

    test "a runtime tree may not define another Raxol.CLI module",
         %{results: results} do
      assert {output, 1} = results["runtime defines another Raxol.CLI module"]

      assert output =~
               ~r/Raxol\.CLI\.Thing\s+defined in raxol, which is runtime-side/
    end

    test "a listed root Raxol.CLI module must be defined by a runtime tree",
         %{results: results} do
      assert {output, 1} = results["root CLI exemption without a definition"]

      assert output =~
               ~r/Raxol\.CLI\.Spinner\s+exempt, but no runtime tree defines it/
    end

    test "an agent tree may not define a module no name rule covers",
         %{results: results} do
      assert {output, 1} = results["agent module without an agent-side name"]
      assert output =~ "agent-side module without an agent-side name"
      assert output =~ ~r/Raxol\.Tools\.Thing\s+defined in raxol_cli$/m
    end
  end

  # {label, [{file, source}]}; a `nil` source removes the base tree's file.
  defp structural_cases do
    [
      {"base", []},
      {"runtime defines an agent namespace",
       [
         {"packages/raxol_core/lib/raxol/agent/thing.ex",
          "defmodule Raxol.Agent.Thing do\nend\n"}
       ]},
      {"runtime defines an exact agent module",
       [
         {"packages/raxol_core/lib/raxol/mcp/agent_bridge.ex",
          "defmodule Raxol.MCP.AgentBridge do\nend\n"}
       ]},
      {"exemption without a definition",
       [
         {"packages/raxol_journal/lib/raxol/agent/journal.ex",
          modules_source(@journal_modules -- ["Raxol.Agent.Journal.Tip"])}
       ]},
      {"allowlist entry within the runtime side",
       [
         {"packages/raxol_core/lib/raxol/core/reach.ex",
          """
          defmodule Raxol.Core.Reach do
            def f, do: Raxol.CLI.Colors.red("x")
          end
          """},
         {"scripts/.package-boundaries-allowlist",
          "packages/raxol_core/lib/raxol/core/reach.ex\tRaxol.CLI.Colors\traxol\n"}
       ]},
      {"allowlist entry across the line",
       [
         {"packages/raxol_cli/lib/raxol/cli/mcp.ex",
          """
          defmodule Raxol.CLI.MCP do
            def f, do: Raxol.Core.Thing.new()
          end
          """},
         {"scripts/.package-boundaries-allowlist",
          "packages/raxol_cli/lib/raxol/cli/mcp.ex\tRaxol.Core.Thing\traxol_core\n"}
       ]},
      {"release catalog without agent applications",
       [
         {"lib/raxol/release/package_check.ex",
          """
          defmodule Raxol.Release.PackageCheck do
            def packages, do: [%{app: :raxol_core, path: "packages/raxol_core"}]
          end
          """}
       ]},
      {"no raxol_cli tree",
       [
         {"packages/raxol_cli/mix.exs", nil},
         {"packages/raxol_cli/lib/raxol/cli/mcp.ex", nil},
         {"config/config.exs",
          """
          import Config
          config :raxol, mcp_authorizer: {Raxol.CLI.MCP, :authorize}
          """}
       ]},
      {"runtime defines another Raxol.CLI module",
       [{"lib/raxol/cli/thing.ex", "defmodule Raxol.CLI.Thing do\nend\n"}]},
      {"root CLI exemption without a definition",
       [
         {"lib/raxol/cli/modules.ex",
          modules_source(@root_cli_modules -- ["Raxol.CLI.Spinner"])}
       ]},
      {"agent module without an agent-side name",
       [
         {"packages/raxol_cli/lib/raxol/tools/thing.ex",
          "defmodule Raxol.Tools.Thing do\nend\n"}
       ]},
      {"package on neither side",
       [{"packages/raxol_other/mix.exs", mix_source(:raxol_other, [])}]}
    ]
  end

  defp build(dir, files) do
    removed = for {file, nil} <- files, do: file

    for {file, source} <- base_tree() ++ files,
        source != nil,
        file not in removed do
      path = Path.join(dir, file)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, source)
    end
  end

  defp check(dir) do
    System.cmd("elixir", [@script, "--root", dir], stderr_to_stdout: true)
  end

  defp base_tree do
    [
      {"mix.exs", mix_source(:raxol, raxol_core: "packages/raxol_core")},
      {"config/config.exs", "import Config\n"},
      {"lib/raxol/cli/modules.ex", modules_source(@root_cli_modules)},
      {"scripts/.package-boundaries-allowlist", "# none\n"},
      {"packages/raxol_core/mix.exs", mix_source(:raxol_core, [])},
      {"packages/raxol_core/lib/raxol/core/thing.ex",
       "defmodule Raxol.Core.Thing do\nend\n"},
      {"packages/raxol_journal/mix.exs", mix_source(:raxol_journal, [])},
      {"packages/raxol_journal/lib/raxol/agent/journal.ex",
       modules_source(@journal_modules)},
      {"packages/raxol_agent/mix.exs",
       mix_source(:raxol_agent,
         raxol: "../..",
         raxol_core: "../raxol_core",
         raxol_journal: "../raxol_journal"
       )},
      {"packages/raxol_agent/lib/raxol/agent/session.ex",
       "defmodule Raxol.Agent.Session do\nend\n"},
      {"packages/raxol_cli/mix.exs", mix_source(:raxol_cli, [])},
      {"packages/raxol_cli/lib/raxol/cli/mcp.ex",
       "defmodule Raxol.CLI.MCP do\nend\n"}
    ]
  end

  defp mix_source(app, deps) do
    entries =
      Enum.map_join(deps, ", ", fn {name, path} ->
        "{#{inspect(name)}, path: #{inspect(path)}}"
      end)

    """
    defmodule #{Macro.camelize(Atom.to_string(app))}.MixProject do
      use Mix.Project
      def project, do: [app: #{inspect(app)}, version: "0.1.0", deps: [#{entries}]]
    end
    """
  end

  defp modules_source(modules) do
    Enum.map_join(modules, "\n", &"defmodule #{&1} do\nend\n")
  end
end
