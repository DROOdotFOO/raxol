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

    test "map field access is not mistaken for dynamic dispatch" do
      # `map.field` and `mod.fun()` are the same AST shape, and reading a map
      # is most of what a REPL session does.
      assert :ok = Sandbox.check("m = %{count: 1}; m.count", :strict)
      assert :ok = Sandbox.check("s.a.b", :strict)
      assert :ok = Sandbox.check("conn.assigns.user", :standard)
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

      # Encoding creates no atoms and stays available.
      assert :ok = Sandbox.check(~s|Jason.encode!(%{a: 1})|, :strict)
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
end
