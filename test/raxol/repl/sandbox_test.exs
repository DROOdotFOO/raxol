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
            ~S|String.replace_leading(s, "0", "")|
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end

      for code <- [
            ~S|String.replace(s, "a", r)|,
            ~S|String.replace(s, "a", "123456789")|,
            ~S|String.replace_leading(s, "a", r)|,
            ~S|String.replace_trailing(s, "a", r)|,
            ~S|Regex.replace(~r/./, s, fn m -> m end)|,
            ~S|f = &String.replace/3; f.(s, "a", r)|
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end
    end

    test "collecting is allowed into a literal list or map, not a string" do
      for code <- [
            "Enum.into(l, %{})",
            "l |> Enum.into([])",
            ~S|Enum.into([a: 1], m)|,
            "for x <- l, into: %{}, do: {x, x}",
            "for x <- l, do: x"
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end

      for code <- [
            ~S|Enum.into(l, "")|,
            ~S|acc = ""; Enum.into(l, acc)|,
            ~S{l |> Stream.into("") |> Stream.run()},
            ~S|for x <- l, into: "", do: x|
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end
    end

    test "other flatteners are refused" do
      for code <- [
            "IO.binwrite(l)",
            ~S|Calendar.strftime(d, "%A", day_of_week_names: f)|,
            ~S|fmt = "%Y"; Calendar.strftime(d, fmt)|
          ] do
        assert {:error, _} = Sandbox.check(code, :strict), "#{code} passed"
      end

      assert :ok = Sandbox.check(~S|Calendar.strftime(d, "%Y-%m-%d")|, :strict)
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

    test "one construction holds at most eight computed binary parts" do
      parts = fn n, sep -> Enum.map_join(1..n, sep, fn _ -> "b" end) end

      assert :ok = Sandbox.check(parts.(8, " <> "), :strict)

      assert :ok =
               Sandbox.check(
                 ~s|"#{parts.(8, "")}"| |> String.replace("b", "\#{b}"),
                 :strict
               )

      assert :ok =
               Sandbox.check(
                 ~S|"a" <> "b" <> "c" <> "d" <> "e" <> "f" <> "g" <> "h" <> "i"|,
                 :strict
               )

      assert {:error, _} = Sandbox.check(parts.(9, " <> "), :strict)

      assert {:error, _} =
               Sandbox.check(
                 ~s|"#{parts.(9, "")}"| |> String.replace("b", "\#{b}"),
                 :strict
               )

      assert {:error, _} =
               Sandbox.check(
                 "<<" <> parts.(9, "::binary, ") <> "::binary>>",
                 :strict
               )
    end

    test "the chunked builders stay available" do
      for code <- [
            "List.to_string(l)",
            "IO.chardata_to_string(l)",
            ~S|"#{l}"|,
            "inspect(l)"
          ] do
        assert :ok = Sandbox.check(code, :strict), "#{code} was refused"
      end
    end

    test ":standard is unaffected" do
      assert :ok = Sandbox.check("Enum.join(l, \",\")", :standard)
      assert :ok = Sandbox.check(~S|n = 5; String.duplicate("x", n)|, :standard)
    end
  end
end
