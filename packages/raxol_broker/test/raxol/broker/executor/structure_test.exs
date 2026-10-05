defmodule Raxol.Broker.Executor.StructureTest do
  @moduledoc """
  The write path's shape, checked from compiled code. Every module of the
  `:raxol_broker` app is read from its BEAM debug info (Erlang abstract
  forms), so an alias, an import or a capture is resolved to the module and
  function it names.

  What this proves, and what it does not:

    * The sinks are restricted by call graph. Only `Raxol.Broker.Executor`
      may reference `Place.run`, `ReviewReceipt.issue`, `Journal.claim` and
      `Port.MCP.start`, whether as a remote call, a remote capture, or a
      literal `Module, :function` pair (an MFA handed to `spawn/3`,
      `Task.async/3`, a child spec and the like). Only `Place` and `Review`
      call `Port.call/4`; only `Port.MCP` and the read-only broker client
      call `Raxol.MCP.Client.call_tool`.
    * Dynamic dispatch is banned, because a call graph cannot see through
      it: no `:erlang.apply/2,3` (`Kernel.apply/2,3` compiles to it), no
      `:erlang.make_fun/3` (`Function.capture/3` compiles to it), no remote
      call or capture whose module or function is not a literal atom, no
      MFA-taking function (`spawn/3`, `Task.async/3`, `:timer.apply_after/4`,
      `Agent.get/4`, ...) given a module or function that is not a literal
      atom, and no no-parens call (`value.name`, which Elixir compiles to a
      remote call on an atom value) whose name is a sink function. The few
      uses in lib are allowlisted below, each with its reason.
    * The atom `:call_tool` (the `Raxol.MCP.Client` request tag) appears
      only in `Port.MCP` and `Raxol.Broker.MCP.Client`, so no other module
      can build a raw `GenServer.call(client, {:call_tool, ...})`. Atoms
      spelling an order tool (`place_..._order` and the like) appear only
      in `Place`.
    * The string scan over the source (order-writing tool names outside
      `executor/place.ex`) is best-effort: a name assembled at runtime from
      fragments passes it. The guarantees are the call-graph rules above and
      the guards at the resources (the journal claim and the receipt key).

  Code that deliberately writes into another module's private state (the
  executor's process-dictionary slots, `:sys.replace_state/2`) is outside
  what a structural test, or the BEAM, can stop.
  """
  use ExUnit.Case, async: true

  alias Raxol.Broker.Executor.{Place, Review, ReviewReceipt}
  alias Raxol.Broker.Journal

  @executor Raxol.Broker.Executor
  @port Raxol.Broker.Executor.Port
  @port_mcp Raxol.Broker.Executor.Port.MCP
  @upstream Raxol.MCP.Client
  @broker_client Raxol.Broker.MCP.Client

  @sinks [{Place, :run}, {ReviewReceipt, :issue}, {Journal, :claim}, {@port_mcp, :start}]
  @sink_functions @sinks |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

  @banned [
    {:erlang, :apply, 2},
    {:erlang, :apply, 3},
    {:erlang, :make_fun, 3},
    {Kernel, :apply, 2},
    {Kernel, :apply, 3},
    {Function, :capture, 3}
  ]

  # `{module, function, arity} => index of the module argument`; the function
  # argument follows it.
  @mfa_takers %{
    {:erlang, :spawn, 3} => 0,
    {:erlang, :spawn, 4} => 1,
    {:erlang, :spawn_link, 3} => 0,
    {:erlang, :spawn_link, 4} => 1,
    {:erlang, :spawn_monitor, 3} => 0,
    {:erlang, :spawn_monitor, 4} => 1,
    {:erlang, :spawn_opt, 4} => 0,
    {:erlang, :spawn_opt, 5} => 1,
    {:proc_lib, :spawn, 3} => 0,
    {:proc_lib, :spawn_link, 3} => 0,
    {:proc_lib, :spawn_opt, 4} => 0,
    {:proc_lib, :start, 3} => 0,
    {:proc_lib, :start, 4} => 0,
    {:proc_lib, :start, 5} => 0,
    {:proc_lib, :start_link, 3} => 0,
    {:proc_lib, :start_link, 4} => 0,
    {:proc_lib, :start_link, 5} => 0,
    {Process, :spawn, 4} => 0,
    {Task, :async, 3} => 0,
    {Task, :start, 3} => 0,
    {Task, :start_link, 3} => 0,
    {Task.Supervisor, :async, 4} => 1,
    {Task.Supervisor, :async, 5} => 1,
    {Task.Supervisor, :async_nolink, 4} => 1,
    {Task.Supervisor, :async_nolink, 5} => 1,
    {Task.Supervisor, :start_child, 4} => 1,
    {Task.Supervisor, :start_child, 5} => 1,
    {Agent, :start, 4} => 0,
    {Agent, :start_link, 4} => 0,
    {Agent, :get, 4} => 1,
    {Agent, :get, 5} => 1,
    {Agent, :update, 4} => 1,
    {Agent, :update, 5} => 1,
    {Agent, :cast, 4} => 1,
    {Agent, :get_and_update, 4} => 1,
    {Agent, :get_and_update, 5} => 1,
    {:timer, :apply_after, 4} => 1,
    {:timer, :apply_interval, 4} => 1,
    {:timer, :apply_repeatedly, 4} => 1,
    {:rpc, :call, 4} => 1,
    {:rpc, :call, 5} => 1,
    {:rpc, :cast, 4} => 1,
    {:erpc, :call, 4} => 1,
    {:erpc, :call, 5} => 1,
    {:erpc, :cast, 4} => 1
  }

  # `{module, finding} => reason` for dynamic dispatch lib legitimately needs.
  @dynamic_allowed %{
    {@port, {:remote_call, :var, :call, 4}} =>
      "Port.call/4 dispatches to the implementation module in the port " <>
        "tuple; only Place and Review may call it, and only the Executor " <>
        "holds a port",
    {@port, {:remote_call, :var, :stop, 1}} =>
      "Port.stop/1 dispatches to the implementation module in the port tuple",
    {Raxol.Broker.CredentialStore, {:remote_call, :var, :load_key, 1}} =>
      "KeyProvider behaviour dispatch to the module KeyProvider.resolve/1 " <>
        "returns; the function name is fixed and is not a sink",
    {Raxol.Broker.CredentialStore, {:remote_call, :var, :create_key, 1}} =>
      "KeyProvider behaviour dispatch to the module KeyProvider.resolve/1 " <>
        "returns; the function name is fixed and is not a sink",
    {Mix.Tasks.Raxol.Broker.Init, {:remote_call, :var, :info, 1}} =>
      "Mix.shell().info/1: Mix's own shell indirection",
    {Mix.Tasks.Raxol.Broker.Init, {:remote_call, :var, :prompt, 1}} =>
      "Mix.shell().prompt/1: Mix's own shell indirection",
    {Mix.Tasks.Raxol.Broker.Replay, {:remote_call, :var, :info, 1}} =>
      "Mix.shell().info/1: Mix's own shell indirection"
  }

  @call_tool_atom_allowed [@port_mcp, @broker_client]
  @order_atom ~r/^(place|cancel|replace)_\w*order/

  setup_all do
    _ = Application.load(:raxol_broker)
    {:ok, modules} = :application.get_key(:raxol_broker, :modules)
    assert @port_mcp in modules
    lib = Path.expand("../../../../lib", __DIR__)

    # In the test env the app also carries `test/support`; only lib ships.
    facts =
      for module <- modules, lib_module?(module, lib) do
        {^module, beam, _path} = :code.get_object_code(module)
        facts(module, beam)
      end

    {:ok, facts: facts}
  end

  defp lib_module?(module, lib) do
    source = module.module_info(:compile) |> Keyword.fetch!(:source) |> List.to_string()
    String.starts_with?(source, lib <> "/")
  end

  # -- The checker ------------------------------------------------------------

  # Everything the rules read from one module: literal remote references
  # (`{m, f, arity}`, `:any` for an MFA pair), dynamic dispatch findings and
  # every atom literal.
  defp facts(module, beam) do
    {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(beam, [:debug_info])

    {:ok, forms} = backend.debug_info(:erlang_v1, module, data, [])
    acc = walk(forms, %{refs: [], dynamic: [], atoms: []})

    %{
      module: module,
      refs: Enum.uniq(acc.refs),
      dynamic: Enum.uniq(acc.dynamic ++ banned_refs(acc.refs)),
      atoms: Enum.uniq(acc.atoms)
    }
  end

  defp banned_refs(refs) do
    for {m, f, a} = mfa <- refs,
        Enum.any?(@banned, &match?({^m, ^f, arity} when a in [arity, :any], &1)),
        do: {:banned, mfa}
  end

  defp walk({:call, _, {:remote, _, {:atom, _, m}, {:atom, _, f}}, args} = node, acc) do
    acc
    |> add(:refs, {m, f, length(args)})
    |> mfa_taker(m, f, args)
    |> no_parens(m, f, args)
    |> then(&walk(Tuple.to_list(node), &1))
  end

  defp walk({:call, _, {:remote, _, m, f}, args} = node, acc),
    do:
      walk(
        Tuple.to_list(node),
        add(acc, :dynamic, {:remote_call, kind(m), name(f), length(args)})
      )

  defp walk({:call, _, {:atom, _, :apply}, args} = node, acc),
    do: walk(Tuple.to_list(node), add(acc, :dynamic, {:local_apply, length(args)}))

  defp walk({:fun, _, {:function, {:atom, _, m}, {:atom, _, f}, {:integer, _, a}}}, acc),
    do: acc |> add(:refs, {m, f, a}) |> add(:atoms, m) |> add(:atoms, f)

  defp walk({:fun, _, {:function, m, f, a}} = node, acc)
       when is_tuple(m) or is_tuple(f) or is_tuple(a),
       do: walk(Tuple.to_list(node), add(acc, :dynamic, {:capture, kind(m), name(f)}))

  defp walk({:atom, _, atom}, acc), do: add(acc, :atoms, atom)
  defp walk(node, acc) when is_tuple(node), do: walk(Tuple.to_list(node), acc)

  defp walk(list, acc) when is_list(list),
    do: list |> mfa_pairs() |> Enum.reduce(acc, &add(&2, :refs, &1)) |> walk_each(list)

  defp walk(_leaf, acc), do: acc

  defp walk_each(acc, list), do: Enum.reduce(list, acc, &walk/2)

  # A literal `Module, :function` pair in any argument list or tuple is a
  # reference to that function, at any arity.
  defp mfa_pairs([{:atom, _, m}, {:atom, _, f} | rest]),
    do: [{m, f, :any} | mfa_pairs([{:atom, 0, f} | rest])]

  defp mfa_pairs([_ | rest]), do: mfa_pairs(rest)
  defp mfa_pairs(_), do: []

  defp mfa_taker(acc, m, f, args) do
    case Map.fetch(@mfa_takers, {m, f, length(args)}) do
      {:ok, index} ->
        case Enum.slice(args, index, 2) do
          [{:atom, _, _}, {:atom, _, _}] ->
            acc

          [mod, fun] ->
            add(acc, :dynamic, {:mfa_taker, {m, f, length(args)}, kind(mod), name(fun)})
        end

      :error ->
        acc
    end
  end

  # `value.name` compiles to `:elixir_erl_pass.no_parens_remote(value, :name)`,
  # which calls `name/0` on `value` when it is a module.
  defp no_parens(acc, :elixir_erl_pass, :no_parens_remote, [_value, {:atom, _, f}])
       when f in @sink_functions,
       do: add(acc, :dynamic, {:no_parens, f})

  defp no_parens(acc, _m, _f, _args), do: acc

  defp add(acc, key, value), do: Map.update!(acc, key, &[value | &1])

  defp kind({:atom, _, atom}), do: atom
  defp kind(_expression), do: :var
  defp name({:atom, _, atom}), do: atom
  defp name(_expression), do: :var

  # -- The rules --------------------------------------------------------------

  defp callers(facts, fun) do
    for %{module: module, refs: refs} <- facts, Enum.any?(refs, fun), uniq: true, do: module
  end

  defp sink?({m, f, _arity}), do: {m, f} in @sinks

  defp sink_violations(facts) do
    for %{module: module, refs: refs} <- facts,
        module != @executor,
        mfa <- refs,
        sink?(mfa),
        do: {module, mfa}
  end

  defp dynamic_violations(facts) do
    for %{module: module, dynamic: dynamic} <- facts,
        finding <- dynamic,
        not Map.has_key?(@dynamic_allowed, {module, finding}),
        do: {module, finding}
  end

  defp call_tool_atom_violations(facts) do
    for %{module: module, atoms: atoms} <- facts,
        module not in @call_tool_atom_allowed,
        :call_tool in atoms,
        do: module
  end

  defp order_atom_violations(facts) do
    for %{module: module, atoms: atoms} <- facts,
        module != Place,
        atom <- atoms,
        Regex.match?(@order_atom, Atom.to_string(atom)),
        do: {module, atom}
  end

  # -- The app ----------------------------------------------------------------

  test "the walker sees remote calls (sanity)", %{facts: facts} do
    place = Enum.find(facts, &(&1.module == Place))
    assert {Journal, :append_to_group, 4} in place.refs
    assert {@executor, :receipt_key, 0} in place.refs
  end

  test "only the Executor references a sink", %{facts: facts} do
    assert sink_violations(facts) == []
    assert callers(facts, &sink?/1) == [@executor]
  end

  test "only Review and Place call Port.call/4", %{facts: facts} do
    assert Enum.sort(callers(facts, &match?({@port, :call, 4}, &1))) == Enum.sort([Place, Review])
  end

  test "nothing calls Port.MCP.call/4 directly; it is reached only through Port",
       %{facts: facts} do
    assert callers(facts, &match?({@port_mcp, :call, _}, &1)) == []
  end

  test "only Port.MCP and the read-only broker client call Raxol.MCP.Client.call_tool",
       %{facts: facts} do
    callers = callers(facts, &match?({@upstream, :call_tool, _}, &1))
    assert @port_mcp in callers
    assert callers -- [@port_mcp, @broker_client] == []
  end

  test "no module uses dynamic dispatch outside the allowlist", %{facts: facts} do
    assert dynamic_violations(facts) == []
  end

  test "every allowlisted dynamic dispatch still exists", %{facts: facts} do
    found =
      for %{module: module, dynamic: dynamic} <- facts, finding <- dynamic, do: {module, finding}

    assert Map.keys(@dynamic_allowed) -- found == []
  end

  test "the :call_tool atom appears only in Port.MCP and the broker client", %{facts: facts} do
    assert call_tool_atom_violations(facts) == []
  end

  test "no atom spells an order tool outside Place", %{facts: facts} do
    assert order_atom_violations(facts) == []
  end

  # -- The rules catch their cases -------------------------------------------

  # Compile `body` into a throwaway module (in memory, never in lib) and
  # return its facts. `mix test` compiles without debug info, so the probe
  # asks for it.
  defp probe(body) do
    module =
      :"Elixir.Raxol.Broker.Executor.StructureTest.Probe#{System.unique_integer([:positive])}"

    [{^module, beam}] =
      Code.compile_string("""
      defmodule #{inspect(module)} do
        @compile :debug_info
        #{body}
      end
      """)

    facts = facts(module, beam)
    :code.purge(module)
    :code.delete(module)
    facts
  end

  test "a direct call, capture or literal MFA of a sink is caught" do
    for body <- [
          "def f(r, i, g, e), do: Raxol.Broker.Executor.Place.run(r, i, g, e)",
          "alias Raxol.Broker.Executor.Place\ndef f, do: &Place.run/4",
          "def f(k, i, g), do: Raxol.Broker.Executor.ReviewReceipt.issue(k, i, g)",
          "def f(j), do: Raxol.Broker.Journal.claim(j)",
          "def f, do: Raxol.Broker.Journal.claim()",
          "def f(s), do: Raxol.Broker.Executor.Port.MCP.start(s, mode: :dry_run)",
          "def f(a), do: Task.async(Raxol.Broker.Executor.Place, :run, a)",
          "def f(a), do: spawn(Raxol.Broker.Journal, :claim, a)",
          "def f, do: {Raxol.Broker.Executor.Port.MCP, :start, [[], []]}"
        ] do
      assert [_ | _] = sink_violations([probe(body)]), body
    end
  end

  test "dynamic dispatch is caught in each form" do
    for body <- [
          "def f(a), do: apply(Raxol.Broker.Executor.Place, :run, a)",
          "def f(m, a), do: :erlang.apply(m, :run, a)",
          "def f(fun, a), do: apply(fun, a)",
          "def f(m), do: Function.capture(m, :run, 4)",
          "def f(m), do: :erlang.make_fun(m, :run, 4)",
          "def f(m, r, i, g, e), do: m.run(r, i, g, e)",
          "def f(fun, a), do: :erlang.apply(Raxol.Broker.Executor.Place, fun, a)",
          "def f, do: {:erlang, :apply}",
          "def f(m), do: &m.run/4",
          "def f(m, a), do: Task.async(m, :run, a)",
          "def f(fun, a), do: spawn(Raxol.Broker.Executor.Place, fun, a)",
          "def f(m, a), do: :timer.apply_after(0, m, :run, a)",
          "def f(m), do: m.claim",
          "def f, do: &Kernel.apply/3"
        ] do
      assert [_ | _] = dynamic_violations([probe(body)]), body
    end
  end

  test "a module held in a variable reaches no sink unseen" do
    facts =
      probe("""
      def f(r, i, g, e) do
        m = Raxol.Broker.Executor.Place
        m.run(r, i, g, e)
      end
      """)

    assert [{_, {:remote_call, :var, :run, 4}}] = dynamic_violations([facts])
  end

  test "a raw GenServer.call with :call_tool is caught" do
    facts = probe("def f(c, t, a), do: GenServer.call(c, {:call_tool, t, a, []})")
    assert call_tool_atom_violations([facts]) == [facts.module]
  end

  test "an atom tool name is caught" do
    for atom <- [":place_equity_order", ":cancel_equity_order", ":replace_option_order"] do
      facts = probe("def f(c), do: c.(#{atom})")
      assert [{_, _}] = order_atom_violations([facts]), atom
    end

    assert order_atom_violations([probe("def f, do: :place_timeout")]) == []
  end

  test "a clean module passes every rule" do
    facts = [probe("def f(x), do: Enum.map(x, &Integer.to_string/1)")]
    assert sink_violations(facts) == []
    assert dynamic_violations(facts) == []
    assert call_tool_atom_violations(facts) == []
    assert order_atom_violations(facts) == []
  end

  # -- Best-effort source scan ------------------------------------------------

  @order_literal ~r/(["'}]|~[a-zA-Z].)(place|cancel|replace)_/

  test "no order-writing tool name is spelled as a string outside executor/place.ex" do
    lib = Path.expand("../../../../lib", __DIR__)
    place = Path.join(lib, "raxol/broker/executor/place.ex")
    files = Path.wildcard(Path.join(lib, "**/*.ex"))
    assert place in files

    offenders =
      for file <- files -- [place],
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(@order_literal, line),
          do: "#{Path.relative_to(file, lib)}:#{number}: #{String.trim(line)}"

    assert offenders == []
  end

  test "the literal check catches the spellings it is meant to" do
    for source <- [
          ~S|"place_equity_order"|,
          ~S|"cancel_" <> kind|,
          ~S|"#{verb}replace_order"|,
          ~S|~s(place_order)|,
          ~S|'cancel_order'|
        ] do
      assert Regex.match?(@order_literal, source), source
    end

    refute Regex.match?(@order_literal, ~S|:place_timeout|)
  end
end
