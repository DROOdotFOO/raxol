defmodule Raxol.REPL.SandboxTest do
  use ExUnit.Case, async: true

  alias Raxol.REPL.Sandbox

  describe "check/2 with :none" do
    test "allows everything" do
      assert :ok = Sandbox.check(~S{System.cmd("rm", ["-rf", "/"])}, :none)
    end
  end

  describe "check/2 with :standard (default)" do
    test "allows safe expressions" do
      assert :ok = Sandbox.check("1 + 2")
      assert :ok = Sandbox.check("Enum.map([1,2,3], & &1 * 2)")
      assert :ok = Sandbox.check("String.upcase(\"hello\")")
      assert :ok = Sandbox.check("x = 42")
      assert :ok = Sandbox.check("[1,2,3] |> Enum.sum()")
    end

    test "allows File.read" do
      assert :ok = Sandbox.check("File.read(\"test.txt\")")
    end

    test "denies System.cmd" do
      {:error, violations} = Sandbox.check("System.cmd(\"ls\", [])")
      assert Enum.any?(violations, &String.contains?(&1, "System.cmd"))
    end

    test "denies System.shell" do
      {:error, violations} = Sandbox.check("System.shell(\"echo hi\")")
      assert Enum.any?(violations, &String.contains?(&1, "System.shell"))
    end

    test "denies System.halt" do
      {:error, violations} = Sandbox.check("System.halt()")
      assert Enum.any?(violations, &String.contains?(&1, "halt"))
    end

    test "denies Port.open" do
      {:error, violations} = Sandbox.check("Port.open({:spawn, \"cat\"}, [])")
      assert Enum.any?(violations, &String.contains?(&1, "Port.open"))
    end

    test "denies File.rm" do
      {:error, violations} = Sandbox.check("File.rm(\"important.txt\")")
      assert Enum.any?(violations, &String.contains?(&1, "File.rm"))
    end

    test "denies File.rm_rf" do
      {:error, violations} = Sandbox.check("File.rm_rf(\"/\")")
      assert Enum.any?(violations, &String.contains?(&1, "File.rm_rf"))
    end

    test "denies File.write" do
      {:error, violations} = Sandbox.check(~S{File.write("x.txt", "data")})
      assert Enum.any?(violations, &String.contains?(&1, "File.write"))
    end

    test "denies Code.eval_string" do
      {:error, violations} = Sandbox.check("Code.eval_string(\"1+1\")")
      assert Enum.any?(violations, &String.contains?(&1, "Code.eval_string"))
    end

    test "denies :os.cmd" do
      {:error, violations} = Sandbox.check(":os.cmd(~c\"ls\")")
      assert Enum.any?(violations, &String.contains?(&1, ":os.cmd"))
    end

    test "denies :erlang.halt" do
      {:error, violations} = Sandbox.check(":erlang.halt()")
      assert Enum.any?(violations, &String.contains?(&1, ":erlang.halt"))
    end

    # A spawned process is not the evaluation, so `Evaluator`'s timeout (which
    # signals one pid) and its per-process heap cap do not reach it. Cover the
    # API families instead of one representative name per module: every entry
    # below can create work that outlives the evaluation that started it.
    test "denies process creation and scheduling variants" do
      for code <- [
            "Task.async(fn -> :ok end)",
            "Task.async_stream([1], fn value -> value end)",
            "Task.start(fn -> :ok end)",
            "Task.start_link(fn -> :ok end)",
            "Task.Supervisor.async_nolink(TaskSupervisor, fn -> :ok end)",
            "Task.Supervisor.start_child(TaskSupervisor, fn -> :ok end)",
            "Agent.start(fn -> 0 end)",
            "Agent.start_link(fn -> 0 end)",
            "GenServer.start(MyServer, :ok)",
            "GenServer.start_link(MyServer, :ok)",
            "Supervisor.start_link([], strategy: :one_for_one)",
            "DynamicSupervisor.start_link(strategy: :one_for_one)",
            "PartitionSupervisor.start_link(child_spec: Task.Supervisor, name: Parts)",
            "Registry.start_link(keys: :unique, name: MyRegistry)",
            "spawn_opt(fn -> :ok end, [])",
            ":erlang.spawn(fn -> :ok end)",
            ":erlang.spawn_link(fn -> :ok end)",
            ":erlang.spawn_monitor(fn -> :ok end)",
            ":erlang.spawn_opt(fn -> :ok end, [])",
            ":erlang.spawn_request(fn -> :ok end)",
            ":proc_lib.spawn(fn -> :ok end)",
            ":proc_lib.start(MyModule, :init, [])",
            ":gen.start(:gen_server, :nolink, MyServer, :ok, [])",
            ":gen_event.start()",
            ":gen_statem.start(MyCallback, :ok, [])",
            ":gen_server.start(MyServer, :ok, [])",
            ":supervisor.start_link(MySupervisor, :ok)",
            ":timer.apply_after(10, Kernel, :send, [self(), :ok])"
          ] do
        assert {:error, [_ | _]} = Sandbox.check(code, :standard),
               "#{code} was allowed at :standard"
      end
    end

    test "denies aliases and imports that hide process APIs" do
      for code <- [
            "alias Task, as: T; T.async(fn -> :ok end)",
            "import Task; async(fn -> :ok end)",
            "require Task; Task.async(fn -> :ok end)",
            "use Task"
          ] do
        assert {:error, [_ | _]} = Sandbox.check(code, :standard),
               "#{code} bypassed the standard policy"
      end
    end

    test "reports syntax errors" do
      {:error, violations} = Sandbox.check("def +++")
      assert Enum.any?(violations, &String.contains?(&1, "Syntax error"))
    end

    test "detects multiple violations" do
      code = """
      System.cmd("ls", [])
      File.rm("test")
      """

      {:error, violations} = Sandbox.check(code)
      assert length(violations) >= 2
    end
  end

  describe "check/2 with :strict" do
    test "allows whitelisted modules" do
      assert :ok = Sandbox.check("Enum.map([1,2,3], & &1 * 2)", :strict)
      assert :ok = Sandbox.check("String.upcase(\"hello\")", :strict)
      assert :ok = Sandbox.check("Map.get(%{a: 1}, :a)", :strict)
      assert :ok = Sandbox.check("List.first([1,2,3])", :strict)
    end

    test "denies non-whitelisted modules" do
      {:error, violations} = Sandbox.check("Agent.start(fn -> 0 end)", :strict)
      assert Enum.any?(violations, &String.contains?(&1, "not in whitelist"))
    end

    test "denies File module entirely" do
      {:error, violations} = Sandbox.check("File.read(\"test.txt\")", :strict)
      assert Enum.any?(violations, &String.contains?(&1, "not in whitelist"))
    end

    test "denies Process module" do
      {:error, violations} = Sandbox.check("Process.list()", :strict)
      assert Enum.any?(violations, &String.contains?(&1, "not in whitelist"))
    end

    test "denies irreversible dynamic atom creation" do
      for code <- [
            ~S[String.to_atom("attacker-controlled")],
            ~S[List.to_atom(~c"attacker-controlled")],
            ~S[Atom.to_string(:ok) |> String.to_atom()]
          ] do
        assert {:error, violations} = Sandbox.check(code, :strict)

        assert Enum.any?(
                 violations,
                 &String.contains?(&1, "dynamic atom creation")
               )
      end
    end
  end

  # The strict level guards an SSH/web-exposed REPL that may share a node with
  # signing processes (the payments wallet GenServer, ledger). Sandboxed code
  # must not be able to message, spawn near, or otherwise reach those processes
  # in the milliseconds before the eval timeout fires.
  describe "capability isolation (cannot reach signing processes)" do
    test "denies Kernel.send to a named process (strict)" do
      assert {:error, _} =
               Sandbox.check(
                 "Kernel.send(Raxol.Payments.Wallets.Op, :x)",
                 :strict
               )
    end

    test "denies Kernel.send to a named process (standard)" do
      assert {:error, _} =
               Sandbox.check(
                 "Kernel.send(Raxol.Payments.Wallets.Op, :x)",
                 :standard
               )
    end

    test "denies the bare send special form" do
      assert {:error, _} = Sandbox.check("send(SomeProc, :msg)", :strict)
    end

    test "denies spawn / spawn_link / spawn_monitor (strict)" do
      assert {:error, _} = Sandbox.check("spawn(fn -> :ok end)", :strict)
      assert {:error, _} = Sandbox.check("spawn_link(fn -> :ok end)", :strict)

      assert {:error, _} =
               Sandbox.check("spawn_monitor(fn -> :ok end)", :strict)
    end

    test "denies :gen_server.call (standard blocklist hole)" do
      assert {:error, _} =
               Sandbox.check(":gen_server.call(Wallet, :m)", :standard)
    end

    test "denies :erlang.send and :rpc.call (standard)" do
      assert {:error, _} = Sandbox.check(":erlang.send(Wallet, :m)", :standard)

      assert {:error, _} =
               Sandbox.check(":rpc.call(node(), M, :f, [])", :standard)
    end

    test "denies Process.send / Process.whereis (standard)" do
      assert {:error, _} = Sandbox.check("Process.whereis(Wallet)", :standard)

      assert {:error, _} =
               Sandbox.check("Process.send(Wallet, :m, [])", :standard)
    end

    test "still allows safe whitelisted computation (strict)" do
      assert :ok = Sandbox.check("Enum.map([1, 2, 3], &(&1 * 2))", :strict)
    end
  end

  # Atoms are never reclaimed, so neither the evaluation timeout nor the heap
  # cap undoes one of these: the table stays grown after the process is killed.
  # Each of these reached an atom-minting primitive that the named blocks above
  # were meant to have closed.
  describe "dynamic atom creation has no back door" do
    test "a computed module cannot be dispatched through" do
      # The check walks names, so a module held in a VARIABLE was invisible to
      # it: `String.to_atom` is blocked, `m.to_atom` was not.
      for level <- [:standard, :strict] do
        assert {:error, [msg]} =
                 Sandbox.check(~s|m = String; m.to_atom("x")|, level)

        assert msg =~ "computed module"
      end
    end

    test "a zero-arity call on a computed module cannot be dispatched through" do
      # The no-parens form was allowed on the premise that the parser sets
      # `no_parens: true` on map field access and not on a call. It sets it on
      # BOTH, and Elixir dispatches the call: this reached `System.halt/0` on an
      # anonymously-exposed SSH REPL, and `System.get_env/0` dumped every
      # secret in the environment. Arity is the only thing the parens form had
      # that this one does not.
      for level <- [:standard, :strict] do
        for code <- [
              "m = System; m.halt",
              "m = System; m.stop",
              "m = System; m.get_env",
              "m = :init; m.stop",
              "m = Process; m.list"
            ] do
          assert {:error, [msg]} = Sandbox.check(code, level),
                 "expected #{inspect(code)} to be refused at #{level}"

          assert msg =~ "computed receiver"
        end
      end
    end

    test "field access has a whitelisted replacement under a sandbox" do
      # Refusing the ambiguous form costs `u.a`, because nothing in the AST
      # separates it from a call. Both replacements stay available, including
      # at :strict where `Map` is whitelisted.
      assert {:error, _} = Sandbox.check("m = %{count: 1}; m.count", :strict)

      assert :ok = Sandbox.check("m = %{count: 1}; m[:count]", :strict)

      assert :ok =
               Sandbox.check("m = %{count: 1}; Map.fetch!(m, :count)", :strict)
    end

    test "dot access is untouched at :none, the local-terminal level" do
      assert :ok = Sandbox.check("m = %{count: 1}; m.count", :none)
      assert :ok = Sandbox.check("conn.assigns.user", :none)
    end

    test ":erlang.apply is denied at standard" do
      assert {:error, _} =
               Sandbox.check(
                 ~s|:erlang.apply(String, :to_atom, ["x"])|,
                 :standard
               )
    end

    test "Module.concat is denied at standard" do
      assert {:error, _} =
               Sandbox.check(~s|Module.concat(["a", "b"])|, :standard)

      assert {:error, _} =
               Sandbox.check(~s|Module.safe_concat(["a", "b"])|, :standard)
    end

    test "Jason.decode is denied even though Jason is whitelisted in strict" do
      # `keys: :atoms` mints an atom per KEY from attacker-supplied JSON, and
      # the option can arrive in a variable, so the call is refused outright.
      assert {:error, _} =
               Sandbox.check(~s|Jason.decode!(j, keys: :atoms)|, :strict)

      assert {:error, _} = Sandbox.check(~s|Jason.decode(j)|, :strict)

      # Encoding creates no atoms and stays available as iodata. `encode!`
      # itself is refused at :strict for its size, not its atoms (below).
      assert :ok = Sandbox.check(~s|Jason.encode_to_iodata!(%{a: 1})|, :strict)
    end
  end

  # The denials above are about atoms the EVALUATION could mint. The checker
  # resolved aliases with `Module.concat/1`, which mints one per alias in the
  # submitted source -- before evaluation, so it happened whether or not the
  # code was allowed to run, and neither the heap cap nor the timeout undoes
  # one. `ReplDemo` is served anonymously over SSH.
  describe "checking untrusted source mints no atoms of its own" do
    # The tokenizer mints the bare alias (`Foo` -> `:Foo`) just to read the
    # source, which is inherent to parsing Elixir and is not what these cover.
    # What the checker added on top was a SECOND atom per alias, the
    # `Elixir.`-prefixed module name, via `Module.concat/1`. That is the half
    # under test.
    #
    # Asserted by NAME rather than by counting `:erlang.system_info(:atom_count)`
    # around the call: this suite is async, so a VM-wide counter also sees every
    # atom the tests running beside it mint, and the count answered 14 in CI for
    # reasons that had nothing to do with this function. The names are exact and
    # cannot drift.
    for level <- [:standard, :strict] do
      test "at #{level}, no module name in the source becomes an atom" do
        names = Enum.map(1..200, &"NoSuchMod#{unquote(level)}#{&1}")
        source = Enum.map_join(names, "\n", &"#{&1}.f()")

        _ = Sandbox.check(source, unquote(level))

        leaked =
          Enum.filter(names, fn name ->
            try do
              _ = :erlang.binary_to_existing_atom("Elixir.#{name}", :utf8)
              true
            rescue
              ArgumentError -> false
            end
          end)

        assert leaked == [],
               "checking #{unquote(level)} source minted #{length(leaked)} " <>
                 "permanent module atoms, e.g. #{inspect(Enum.take(leaked, 3))}"
      end
    end

    test "an unknown module is still refused at strict, by name" do
      assert {:error, violations} =
               Sandbox.check("Definitely.Not.Loaded.run()", :strict)

      assert Enum.any?(violations, &String.contains?(&1, "not in whitelist"))
    end

    test "a whitelisted module still resolves at strict" do
      assert :ok = Sandbox.check("Enum.map([1], & &1)", :strict)
    end

    test "a denied module still resolves at standard" do
      assert {:error, violations} = Sandbox.check(~s|System.cmd("ls", [])|)
      assert Enum.any?(violations, &String.contains?(&1, "System.cmd"))
    end

    test "an unknown module is allowed at standard, as before" do
      # It is not on the denylist, and there is no such module to dispatch to.
      assert :ok = Sandbox.check("Definitely.Not.Loaded.run()", :standard)
    end
  end

  # Every clause in the checker decides safety from a module NAME. `import`,
  # `alias`, `require` and `use` decide which module a name reaches, so they
  # sit underneath the check rather than inside it: at `:strict`, the level
  # documented as safe for anonymous exposure, `import System; cmd("id", [])`
  # and `alias :os, as: Enum; Enum.cmd(~c"id")` both returned `:ok` and both
  # executed as the node's OS user (#1045).
  describe "name rebinding cannot reach a denied module" do
    test "import lets a denied call through as a bare local call" do
      for level <- [:standard, :strict] do
        assert {:error, violations} =
                 Sandbox.check(~s|import System; cmd("id", [])|, level)

        assert Enum.any?(violations, &String.contains?(&1, "import"))
      end
    end

    test "alias rebinds a whitelisted name onto a denied module" do
      for level <- [:standard, :strict] do
        assert {:error, violations} =
                 Sandbox.check(~s|alias :os, as: Enum; Enum.cmd(~c"id")|, level)

        assert Enum.any?(violations, &String.contains?(&1, "alias"))
      end
    end

    test "require and use are refused for the same reason" do
      for code <- ["require Logger", "use GenServer"],
          level <- [:standard, :strict] do
        assert {:error, _violations} = Sandbox.check(code, level)
      end
    end

    test "none still allows them -- it is the local-terminal level" do
      assert :ok = Sandbox.check(~s|import System; cmd("id", [])|, :none)
    end

    test "code that names its modules in full is unaffected" do
      for code <- [
            "Enum.map([1, 2], & &1 * 2)",
            ~s|String.upcase("hi")|,
            "x = 1; x + 2"
          ] do
        assert :ok = Sandbox.check(code, :strict)
      end
    end
  end

  # A capture writes the same local call with `args == nil`, so the
  # `is_list(args)` guards on the `apply`, `send` and spawn clauses skipped it
  # and the node fell through to the catch-all. `(&apply/3).(:os, :cmd, ...)`
  # and `Enum.map([f], &spawn/1)` both returned `:ok` at `:strict` and both do
  # exactly what the unwrapped call would (#1045 review).
  describe "the capture form of a denied local reaches no further than the call" do
    for {code, reason} <- [
          {"(&apply/3).(:os, :cmd, [~c\"id\"])",
           "dynamic function application"},
          {"f = &apply/3", "dynamic function application"},
          {"&send/2", "message sending"},
          {"Enum.map([fn -> 1 end], &spawn/1)", "process spawning"},
          {"&spawn_link/1", "process spawning"},
          {"&spawn_monitor/1", "process spawning"}
        ] do
      test "strict refuses #{code}" do
        assert {:error, violations} = Sandbox.check(unquote(code), :strict)

        assert Enum.any?(violations, &String.contains?(&1, unquote(reason))),
               "expected a #{unquote(reason)} violation, got #{inspect(violations)}"
      end
    end

    test "a qualified capture of a denied module is still refused" do
      for code <- ["&:os.cmd/1", "&File.read!/1", "&Kernel.apply/3"] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} was allowed"
      end
    end

    # The denial belongs on the capture form, not on the name: these are the
    # shapes that must keep working, including a variable that happens to be
    # called `apply`.
    test "ordinary captures and a variable named apply still pass" do
      for code <- [
            "&Enum.map/2",
            "Enum.map([1, 2], &(&1 * 2))",
            "apply = 1; apply + 1"
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end
    end

    test "none still allows the capture form" do
      assert :ok = Sandbox.check("(&apply/3).(:os, :cmd, [~c\"id\"])", :none)
    end
  end

  # `:max_heap_size` is checked at GC, so a builtin that sizes its whole
  # result up front allocates before the kill, and one the allocator cannot
  # satisfy aborts the node (`String.duplicate("x", 10**15)` did, through
  # the served evaluator). #1231 is the real fix; these pin the denylist.
  describe ":strict refuses single-allocation amplifiers" do
    test "flatteners are refused in every form" do
      for code <- [
            "IO.iodata_to_binary(l)",
            "Enum.join(l, \",\")",
            "Enum.map_join(l, \",\", & &1)",
            "Jason.encode!(l)",
            "Jason.encode(l)",
            "l |> Enum.join()",
            "Enum.map([l], &IO.iodata_to_binary/1)"
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end
    end

    test "repeaters pass only when what they multiply is literal and small" do
      for code <- [
            ~S|String.duplicate("-", 20)|,
            ~S|String.pad_leading("42", 5, "0")|,
            ~S|String.pad_trailing("a", 3)|,
            "Tuple.duplicate(0, 4)",
            # Padding and tuples do not multiply their subject or data, so
            # those may be computed, and the piped forms stay available.
            ~S|String.pad_leading(Integer.to_string(7), 3, "0")|,
            ~S|name = "ab"; String.pad_trailing(name, 10)|,
            ~S{Integer.to_string(5) |> String.pad_leading(3, "0")},
            "x = :a; Tuple.duplicate(x, 4)",
            # 200 KB of one-byte string is under the 1 MiB bound.
            ~S|String.duplicate("-", 200_000)|
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end

      for code <- [
            ~S|String.duplicate("x", 1_000_000_000_000_000)|,
            ~S|String.pad_leading("", 1_000_000_000_000_000)|,
            "Tuple.duplicate(0, 16_000_000)",
            # 2 KB x 1 000 is over the bound even though each part is small.
            "String.duplicate(\"#{String.duplicate("x", 2048)}\", 1_000)",
            ~S|n = 5; String.duplicate("x", n)|,
            ~S|s = "x"; String.duplicate(s, 5)|,
            ~S|String.duplicate("x", 2 * 5)|,
            ~S|n = 5; String.pad_leading("x", n)|,
            ~S|p = "0"; String.pad_leading("x", 5, p)|,
            # Both pipe forms leave the multiplied subject out of the call.
            ~S{s = "x"; s |> String.duplicate(5)},
            ~S{s = "x"; Kernel.|>(s, String.duplicate(5))},
            ~S|f = &String.duplicate/2; f.("x", 5)|,
            ~S|Enum.map([5], &String.duplicate("x", &1))|
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end
    end

    test "replacements must be short literals" do
      for code <- [
            ~S|String.replace(s, " ", "_")|,
            ~S{s |> String.replace("\n", "<br>")},
            ~S|String.replace(s, "a", "b", global: false)|,
            ~S|Regex.replace(~r/\s+/, s, " ")|,
            ~S|String.replace_leading(s, "0", "")|,
            ~S|String.replace(s, "a", "b", [])|,
            ~S|Regex.replace(~r/a/, s, "x", [])|
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end

      for code <- [
            ~S|String.replace(s, "a", r)|,
            ~S|String.replace(s, "a", "123456789")|,
            ~S|String.replace_leading(s, "a", r)|,
            ~S|String.replace_trailing(s, "a", r)|,
            ~S|Regex.replace(~r/./, s, fn m -> m end)|,
            ~S|f = &String.replace/3; f.(s, "a", r)|,
            ~S|String.replace(s, "a", "b", opts)|
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end

      # `insert_replaced:` inserts the match once per listed position.
      assert {:error, [message]} =
               Sandbox.check(
                 ~S|String.replace(s, s, "", insert_replaced: List.duplicate(0, 64))|,
                 :strict
               )

      assert message =~ "options other than :global"
    end

    test "collecting is decided by the target, never the source" do
      for code <- [
            "l |> Enum.into([])",
            "Enum.into(l, MapSet.new())",
            "Enum.into(l, MapSet.new([1]))",
            "for x <- l, into: MapSet.new(), do: x",
            "for x <- l, do: x",
            # A source written out in full is bounded by the source text.
            ~S|Enum.into([a: 1], m)|
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end

      for code <- [
            ~S|Enum.into(l, "")|,
            ~S|acc = ""; Enum.into(l, acc)|,
            # A literal SOURCE list can still hold references to big binaries.
            ~S|Enum.into([b, b, b], "")|,
            ~S<Enum.into(["" | l], "")>,
            # A placeholder is a value, not the piped form's transform.
            ~S|f = &Enum.into([b, b, b], &1); f.("")|,
            # A transform grows each element of even a literal source.
            ~S|Enum.into([1, 2], "", fn _ -> b end)|,
            ~S{l |> Enum.into("", fn x -> x end)},
            ~S{l |> Stream.into("") |> Stream.run()},
            ~S|for x <- l, into: "", do: x|
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end
    end

    test "other flatteners are refused unless their input is written out" do
      for code <- [
            "IO.binwrite(l)",
            "List.to_string(l)",
            "IO.chardata_to_string(l)",
            ~S{l |> Enum.join(", ")},
            ~S|Enum.map_join(["a"], ",", fn _ -> b end)|,
            ~S|Calendar.strftime(d, "%A", day_of_week_names: f)|,
            ~S|fmt = "%Y"; Calendar.strftime(d, fmt)|,
            # `%Z` copies the input map's `:zone_abbr`, any binary.
            ~S|Calendar.strftime(%{zone_abbr: z}, "%Z%Z%Z")|,
            ~S|Calendar.strftime(d, "%-10Z")|
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end

      for code <- [
            ~S|List.to_string(~c"abc")|,
            ~S|List.to_string(["a", ?b])|,
            ~S|IO.chardata_to_string(["a", ?b])|,
            ~S|Enum.join(["a", "b"], ", ")|,
            ~S|Calendar.strftime(d, "%Y-%m-%d")|,
            # `%%` is an escaped percent: this prints the text "100%Z".
            ~S|Calendar.strftime(d, "100%%Z")|
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end
    end

    test "bitstring segments must be literal and bounded" do
      for code <- [
            "<<1, 2, 3>>",
            "<<0::size(8)>>",
            "<<0::16>>",
            "<<\"ab\"::binary-size(2)>>",
            "s = \"ab\"; <<s::binary, \"c\">>"
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end

      for code <- [
            "n = 8; <<0::size(n)>>",
            "<<0::size(8_000_000_000)>>",
            "<<0::size(100_000)-unit(256)>>",
            "u = 8; <<0::size(1)-unit(u)>>",
            "<<0::8_000_000_000>>",
            # `size*unit` shorthand.
            "<<0::1_000_000_000*256>>",
            "n = 8; <<0::n*8>>"
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end
    end

    # erl_eval appends segments one at a time, so the cap sees these grow.
    test "interpolation and <> chains are not limited by part count" do
      many = Enum.map_join(1..20, "", fn _ -> "\#{b}" end)
      assert :ok = Sandbox.check(~s|"#{many}"|, :strict)

      assert :ok =
               Sandbox.check(
                 Enum.map_join(1..20, " <> ", fn _ -> "b" end),
                 :strict
               )
    end

    test ":standard is unaffected" do
      assert :ok = Sandbox.check("Enum.join(l, \",\")", :standard)
      assert :ok = Sandbox.check(~S|n = 5; String.duplicate("x", n)|, :standard)
    end
  end

  # A map whose `__struct__` key names a module dispatches to that module's
  # protocol impls, so building one reaches code no call in the source names.
  describe ":strict refuses forged structs where the map is built" do
    @file_stream ~S<%{__struct__: File.Stream, path: "/tmp/raxol_probe", modes: [], raw: true, line_or_bytes: :line, node: node()}>

    test "a forged File.Stream bound to a variable is refused (regression)" do
      # `Enum.into/2` saw only the literal source `["hi"]` and the variable,
      # so this passed `:strict` and wrote the file.
      code = "m = #{@file_stream}; Enum.into([\"hi\"], m)"

      assert {:error, [message]} = Sandbox.check(code, :strict)
      assert message =~ "map key"
    end

    test "literal and computed __struct__ keys are refused" do
      for code <- [
            "Enum.into([\"hi\"], #{@file_stream})",
            "m = #{@file_stream}; [\"hi\"] |> Enum.into(m)",
            "m = #{@file_stream}; for x <- [\"hi\"], into: m, do: x",
            "Enum.count(#{@file_stream})",
            ~S|"#{%{__struct__: URI, host: "x"}}"|,
            ~S|k = :__struct__; %{k => File.Stream}|,
            ~S|k = String.to_existing_atom("__struct__"); %{k => File.Stream}|,
            ~S'%{u | __struct__: File.Stream}',
            ~S'%{u | k => 1}',
            # Patterns share the shape and fail closed.
            ~S|%{__struct__: s} = %{__struct__: 1}|,
            ~S|%{^k => v} = m|
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end
    end

    test "struct literals and struct/2 may only name allowlisted modules" do
      for code <- [
            ~S|%File.Stream{path: "/tmp/x"}|,
            ~S|%Regex{}|,
            ~S|%mod{} = x|,
            ~S|struct(File.Stream, path: "/tmp/x")|,
            ~S|Kernel.struct!(File.Stream, path: "/tmp/x")|,
            ~S|mod = String.to_existing_atom("Elixir.File.Stream"); struct(mod, [])|,
            ~S|&struct/2|,
            ~S|&Kernel.struct!/2|
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end

      for code <- [
            ~S|%URI{host: "x"}|,
            ~S'%URI{u | host: "x"}',
            ~S|%Date{year: 2020, month: 1, day: 1}|,
            ~S|%MapSet{} = s|,
            ~S|struct(URI, host: "x")|,
            # `struct/2` drops a `__struct__` field, so the fields may be computed.
            ~S|struct(URI, fields)|
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end
    end

    test "calls that write a key from runtime data are refused" do
      for code <- [
            ~S|Map.put(%{path: "/tmp/x"}, :__struct__, File.Stream)|,
            ~S'%{} |> Map.put(:__struct__, File.Stream)',
            ~S|Map.put(%{}, k, File.Stream)|,
            ~S|Map.update!(u, :__struct__, fn _ -> File.Stream end)|,
            ~S|Map.replace(u, :__struct__, File.Stream)|,
            ~S|Map.get_and_update(%{}, k, f)|,
            ~S|Access.get_and_update(%{}, :__struct__, f)|,
            ~S|Map.new([{:__struct__, File.Stream}])|,
            ~S|Map.new([{k, File.Stream}])|,
            ~S|Map.new(pairs)|,
            ~S'pairs |> Map.new()',
            ~S'Kernel.|>(pairs, Map.new())',
            ~S|Map.new(l, fn x -> {x, x} end)|,
            ~S|Map.from_keys(keys, File.Stream)|,
            # Both maps can be real structs; the resolver picks the value.
            ~S|Map.merge(%URI{}, %URI{}, fn _, _, _ -> File.Stream end)|,
            ~S'f = fn _, _, _ -> File.Stream end; u |> Map.merge(u, f)',
            ~S|Map.intersect(u, u, f)|,
            ~S|Map.map(u, f)|,
            ~S|Enum.into([__struct__: File.Stream], %{})|,
            ~S|Enum.into(pairs, %{})|,
            ~S|Enum.into(pairs, Map.new())|,
            ~S|Enum.into([x], %{})|,
            ~S'l |> Enum.into(%{}, fn x -> {x, x} end)',
            ~S|Stream.into(pairs, %{})|,
            ~S|for x <- l, into: %{}, do: {x, x}|,
            ~S|Enum.reduce(l, %{}, fn {k, v}, acc -> Map.put(acc, k, v) end)|,
            ~S|&Map.put/3|,
            ~S|Enum.map(l, &Map.new/1)|
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end
    end

    test "every one-key writer refuses a computed key, direct, piped and captured" do
      writers = [
        {"Map.put", 3},
        {"Map.put_new", 3},
        {"Map.put_new_lazy", 3},
        {"Map.replace", 3},
        {"Map.replace!", 3},
        {"Map.replace_lazy", 3},
        {"Map.update", 4},
        {"Map.update!", 3},
        {"Map.get_and_update", 3},
        {"Map.get_and_update!", 3},
        {"Access.get_and_update", 3}
      ]

      for {name, arity} <- writers,
          rest = Enum.map_join(3..arity//1, "", fn _ -> ", v" end),
          code <- [
            "#{name}(m, k#{rest})",
            "m |> #{name}(k#{rest})",
            "&#{name}/#{arity}"
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end
    end

    test "a bare name piped into struct/struct! is checked as the call" do
      # `Kernel.|>` expands `x |> struct` to `struct(x)`.
      for code <- [
            ~S"File.Stream |> struct",
            ~S"File.Stream |> struct!",
            ~S"Kernel.|>(File.Stream, struct!)"
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end

      assert :ok = Sandbox.check(~S"URI |> struct", :strict)
    end

    test "Access.values and Access.key are refused outside a path too" do
      # A `__struct__` key planted with a harmless value can be rewritten.
      for code <- [
            ~S|Access.values().(:get_and_update, Enum.frequencies(l), g)|,
            ~S|f = Access.values(); f.(:get_and_update, m, g)|,
            ~S|&Access.values/0|,
            ~S|Access.key(k).(:get_and_update, m, g)|,
            ~S|&Access.key/1|
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end
    end

    test "a refused computed struct literal does not echo its expression" do
      code = Enum.reduce(1..50, "%x{}", fn _, acc -> "%f(#{acc}){}" end)

      assert {:error, messages} = Sandbox.check(code, :strict)
      refute Enum.any?(messages, &(&1 =~ "%f("))
    end

    test "access paths must be literal keys or list selectors" do
      for code <- [
            ~S|put_in(%{}, [:__struct__], File.Stream)|,
            ~S|put_in(%{}, [k], File.Stream)|,
            ~S|put_in(%{}, path, File.Stream)|,
            ~S'%{} |> put_in([k], File.Stream)',
            ~S|put_in(m[k], File.Stream)|,
            ~S|put_in(m[:a][:__struct__], File.Stream)|,
            # Rewrites every value, including a `__struct__` one.
            ~S|update_in(m, [Access.values()], fn _ -> File.Stream end)|,
            ~S|update_in(m, [Access.key(:__struct__)], fn _ -> File.Stream end)|,
            ~S|get_and_update_in(m, [k], f)|,
            ~S|&put_in/3|
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end

      for code <- [
            ~S|put_in(m, [:a, :b], 1)|,
            ~S|put_in(m[:a]["b"], 1)|,
            ~S|update_in(m, [:a, Access.all(), :b], &(&1 + 1))|,
            ~S|update_in(m, [Access.key(:a, %{})], fn x -> x end)|,
            ~S|get_in(m, [k])|,
            ~S|pop_in(m, [k])|
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end
    end

    test "plain maps with literal keys are unaffected" do
      for code <- [
            ~S|%{"a" => 1, {1, 2} => 3, b: 2}|,
            # A container key can never evaluate to `:__struct__`.
            ~S|%{"#{x}" => 1, {a, b} => 2, [k] => 3}|,
            ~S|Map.put(m, "#{k}", 1)|,
            ~S|%{} = x = %{a: 1}|,
            ~S'%{state | count: 1}',
            ~S|Map.merge(%{}, %{"x" => 1})|,
            ~S'a |> Map.merge(b)',
            ~S|Map.from_struct(%{a: 1})|,
            ~S|Map.put(m, :a, 1)|,
            ~S'm |> Map.put("a", 1)',
            ~S|Map.update(m, :count, 0, &(&1 + 1))|,
            ~S|Map.get(m, k)|,
            ~S|Map.delete(m, k)|,
            ~S|Map.new()|,
            ~S|Map.new(a: 1, b: x)|,
            ~S|Map.from_keys([:a, :b], 0)|,
            ~S|Enum.into([a: x], %{})|,
            ~S|Enum.frequencies(l)|
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end
    end
  end

  describe ":strict refuses generated and internal functions of allowlisted modules" do
    test "every __-prefixed function and macro is refused in every call form" do
      for mod <- Sandbox.strict_modules(),
          {name, arity} <- mod.__info__(:functions) ++ mod.__info__(:macros),
          String.starts_with?(Atom.to_string(name), "__") do
        m = inspect(mod)
        args = Enum.map_join(1..arity//1, ", ", &"a#{&1}")

        rest =
          if arity > 1,
            do: Enum.map_join(2..arity//1, ", ", &"a#{&1}"),
            else: ""

        forms = [
          "#{m}.#{name}(#{args})",
          ~s|:"Elixir.#{m}".#{name}(#{args})|,
          "&#{m}.#{name}/#{arity}"
        ]

        forms =
          if arity >= 1,
            do:
              forms ++
                [
                  "a1 |> #{m}.#{name}(#{rest})",
                  "&#{m}.#{name}(&1#{if rest != "", do: ", " <> rest})"
                ],
            else: forms

        for code <- forms do
          assert {:error, _} = Sandbox.check(code, :strict),
                 "#{code} passed :strict"
        end
      end
    end

    test "__struct__/1 regressions" do
      for code <- [
            "URI.__struct__(kv)",
            "MapSet.__struct__(kv)",
            "kv |> URI.__struct__()",
            "Kernel.|>(kv, URI.__struct__())",
            ~S|:"Elixir.URI".__struct__(kv)|,
            "&URI.__struct__/1",
            "&URI.__struct__(&1)",
            "Regex.__import_pattern__(p)"
          ] do
        assert {:error, _} = Sandbox.check(code, :strict),
               "#{code} passed :strict"
      end
    end

    test "ordinary allowlisted calls still pass" do
      for code <- [
            ~S|URI.parse("http://x")|,
            ~S|%URI{host: "x"}|,
            ~S|struct(URI, host: "x")|,
            "MapSet.new(l)"
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end
    end
  end

  # One row per rule entry, in every call form, so deleting an entry (or a
  # call form slipping past one) fails a row of its own instead of hiding
  # behind another node of the same input that refuses it. `update_in(m,
  # [Access.values()], f)` above, for instance, is refused by the inner
  # `Access.values()` whether or not `update_in` is a forge call.
  describe ":strict forge rules hold for every entry and call form" do
    # {name, first argument, remaining arguments, arity}: the computed
    # argument (module or path) is the only thing that can refuse each row.
    @kernel_forge_calls [
      {"struct", "mod", "[]", 2},
      {"struct!", "mod", "[]", 2},
      {"put_in", "m", "[k], v", 3},
      {"update_in", "m", "[k], f", 3},
      {"get_and_update_in", "m", "[k], f", 3}
    ]

    # {module, function, first argument, remaining arguments or nil, arity}
    @forge_rule_calls [
      {"Map", "new", "pairs", nil, 1},
      {"Map", "new", "l", "f", 2},
      {"Map", "from_keys", "keys", "v", 2},
      {"Map", "merge", "a", "b, f", 3},
      {"Map", "intersect", "a", "b, f", 3},
      {"Map", "map", "m", "f", 2},
      {"Enum", "into", "pairs", "%{}", 2},
      {"Stream", "into", "pairs", "%{}", 2},
      {"Access", "key", "k", nil, 1},
      # Piped, the node alone reads the default as the key; only the pipe
      # rebuild sees `k`.
      {"Access", "key", "k", "%{}", 2},
      {"Access", "key!", "k", nil, 1},
      {"Access", "key!", "k", "%{}", 2}
    ]

    defp call_args(first, nil), do: first
    defp call_args(first, rest), do: "#{first}, #{rest}"

    defp kernel_forms(name, first, rest) do
      [
        "#{name}(#{first}, #{rest})",
        "Kernel.#{name}(#{first}, #{rest})",
        ~s|:"Elixir.Kernel".#{name}(#{first}, #{rest})|
      ]
    end

    defp kernel_pipe_forms(name, first, rest) do
      [
        "#{first} |> #{name}(#{rest})",
        "#{first} |> Kernel.#{name}(#{rest})",
        "Kernel.|>(#{first}, #{name}(#{rest}))"
      ]
    end

    test "each Kernel forge call refuses a computed module or path in every form" do
      for {name, first, rest, arity} <- @kernel_forge_calls,
          code <-
            kernel_forms(name, first, rest) ++
              kernel_pipe_forms(name, first, rest) ++
              [
                "&#{name}/#{arity}",
                "&Kernel.#{name}/#{arity}",
                "&#{name}(&1, #{rest})",
                "&Kernel.#{name}(&1, #{rest})"
              ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end
    end

    test "each Kernel forge call allows a literal module or path" do
      rows = [
        {"struct", "URI", "[]"},
        {"struct!", "URI", "[]"},
        {"put_in", "m", "[:a], v"},
        {"update_in", "m", "[:a], f"},
        {"get_and_update_in", "m", "[:a], f"}
      ]

      # A piped struct/2 is refused whatever it names: the node alone has
      # its fields where the module goes. A bare piped name is checked as the
      # call (see above).
      for {name, first, rest} <- rows,
          code <-
            kernel_forms(name, first, rest) ++
              if(name in ["struct", "struct!"],
                do: [],
                else: kernel_pipe_forms(name, first, rest)
              ) do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end
    end

    test "each forge_rule clause refuses in direct, piped, atom-module and captured forms" do
      for {mod, fun, first, rest, arity} <- @forge_rule_calls,
          atom_mod = ~s|:"Elixir.#{mod}"|,
          code <- [
            "#{mod}.#{fun}(#{call_args(first, rest)})",
            "#{first} |> #{mod}.#{fun}(#{rest})",
            "Kernel.|>(#{first}, #{mod}.#{fun}(#{rest}))",
            "#{atom_mod}.#{fun}(#{call_args(first, rest)})",
            "#{first} |> #{atom_mod}.#{fun}(#{rest})",
            "&#{mod}.#{fun}/#{arity}",
            "&#{atom_mod}.#{fun}/#{arity}",
            "&#{mod}.#{fun}(#{call_args("&1", rest)})"
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end

      for code <- [
            "Access.values()",
            "x |> Access.values()",
            "Kernel.|>(x, Access.values())",
            ~S|:"Elixir.Access".values()|,
            "&Access.values/0",
            ~S|&:"Elixir.Access".values/0|,
            "&Access.values(&1)"
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end
    end

    test "the same calls with literal keys and entries are allowed" do
      for code <- [
            "Map.new([a: 1])",
            "[a: 1] |> Map.new()",
            "Map.from_keys([:a, \"b\"], 0)",
            "Enum.into([a: 1], %{})",
            "Stream.into([a: 1], %{})",
            "Access.key(:a)",
            # The node alone reads `%{}` as the key, the rebuilt call `:a`.
            ":a |> Access.key(%{})",
            "Kernel.|>(:a, Access.key!(%{}))"
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end
    end

    test "every allowlisted struct module may be built, as a literal and in struct/2" do
      for module <- ~w(URI Date Time DateTime NaiveDateTime Range MapSet),
          code <- [
            "%#{module}{}",
            "struct(#{module}, [])",
            "Kernel.struct!(#{module}, [])",
            "#{module} |> struct"
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end
    end

    test "every Access list selector may appear in a path" do
      for selector <-
            ~w[all() at(0) at!(0) elem(0) filter(g) find(g) slice(0..1)],
          code <- [
            "update_in(m, [Access.#{selector}], f)",
            "put_in(m, [:a, Access.#{selector}], v)",
            "m |> get_and_update_in([Access.#{selector}, :b], f)"
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end
    end

    test "an alias is a plain map key" do
      for code <- [
            ~S|%{Foo => 1}|,
            ~S|%{URI => 1, Foo.Bar => 2}|,
            ~S'%{m | Foo => 1}',
            ~S|Map.put(m, Foo, 1)|,
            ~S|put_in(m, [Foo], 1)|
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end
    end

    # The computed-key refusals name these forms as the way out, so each must
    # stay allowed for the messages to stay true.
    test "the alternatives the refusals name are allowed" do
      for code <- [
            ~S|%{"#{k}" => v}|,
            ~S|%{{k} => v}|,
            ~S|Map.put(m, "#{k}", v)|,
            ~S|Map.put_new(m, {k}, v)|,
            ~S|put_in(m, ["#{k}"], v)|,
            ~S|Access.key("#{k}")|,
            ~S|Enum.reduce(l, %{}, fn x, acc -> Map.put(acc, "#{x}", x) end)|,
            ~S|Enum.reduce(l, %{}, fn x, acc -> Map.put(acc, {x}, x) end)|,
            ~S|Enum.frequencies(l)|,
            ~S|Enum.group_by(l, f)|,
            ~S|Enum.group_by(l, f, g)|,
            ~S|Enum.into(l, [])|,
            ~S|Enum.into(l, MapSet.new())|,
            ~S|Stream.into(l, [])|,
            ~S|for x <- l, into: [], do: x|,
            ~S|for x <- l, into: MapSet.new(), do: x|
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end
    end
  end

  # `IO` hands any atom, pid or tuple device to `:io`, which sends an io
  # request to that process: `IO.write(Raxol.Payments.Wallets.Op, "x")`
  # messaged the process `Kernel.send/2` is refused for, and bypassed the
  # evaluator's output capture on the way. `:stderr` and `IO.warn` bypass
  # the capture too, onto the node's real stderr.
  describe ":strict IO calls may only name the standard devices" do
    test "a named, computed or piped device is refused in every call form" do
      for code <- [
            ~S{IO.write(:some_name, "x")},
            ~S{IO.write(Raxol.Payments.Wallets.Op, "x")},
            ~S{IO.puts(:logger, "x")},
            ~S{IO.read(:code_server, :line)},
            ~S{IO.binread(:code_server, :line)},
            ~S{IO.gets(:user, "p")},
            ~S{IO.getn(:n, "p")},
            ~S{IO.getn(dev, p)},
            ~S{IO.getn(:n, "p", 1)},
            ~S{IO.inspect(:n, x, [])},
            ~S{IO.stream(dev, :line)},
            ~S{IO.binstream(dev, :line)},
            ~S{IO.write(self(), "x")},
            ~S{:some_name |> IO.write("x")},
            ~S{:n |> IO.inspect(x, [])},
            ~S{Kernel.|>(:n, IO.puts("x"))},
            ~S{:"Elixir.IO".write(:n, "x")},
            ~S{&IO.write/2},
            ~S{&IO.inspect/3},
            ~S{&IO.write(&1, "x")},
            ~S{Enum.into(["x"], IO.stream(:n, :line))},
            ~S{IO.write(:stderr, "x")},
            ~S{IO.puts(:standard_error, "x")},
            ~S{:stderr |> IO.write("x")},
            ~S{IO.inspect(:stderr, x, [])}
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end
    end

    test "IO.warn writes to the node's stderr and is refused in every form" do
      for code <- [
            ~S{IO.warn("x")},
            ~S{IO.warn("x", [])},
            ~S{IO.warn("x", file: "/etc/passwd", line: 1)},
            ~S{"x" |> IO.warn()},
            ~S{Kernel.|>("x", IO.warn([]))},
            ~S{:"Elixir.IO".warn("x")},
            ~S{&IO.warn/1},
            ~S{&IO.warn/2},
            ~S{Enum.each(l, &IO.warn/1)},
            ~S{&IO.warn(&1, [])},
            ~S{IO.warn_once(:k, "x", 0)}
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end
    end

    test "the standard devices and the default-device arities are allowed" do
      for code <- [
            ~S{IO.puts("x")},
            ~S{IO.puts(:stdio, "x")},
            ~S{IO.write(:standard_io, "x")},
            ~S{IO.gets(:standard_io, "p")},
            ~S{:standard_io |> IO.puts("x")},
            ~S{"x" |> IO.puts()},
            ~S{:stdio |> IO.write("x")},
            ~S{IO.inspect(x, label: "a")},
            ~S{x |> IO.inspect()},
            ~S{x |> IO.inspect(label: "a")},
            ~S{IO.inspect(:stdio, x, [])},
            ~S{IO.getn("p", 3)},
            ~S{IO.getn("p", :eof)},
            ~S{IO.write("x")},
            ~S{&IO.puts/1},
            ~S{&IO.write(:stdio, &1)},
            ~S{Enum.each(l, &IO.puts/1)}
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end
    end
  end
end
