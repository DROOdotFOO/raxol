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
end
