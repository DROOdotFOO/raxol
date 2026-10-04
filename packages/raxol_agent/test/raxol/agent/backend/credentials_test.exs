defmodule Raxol.Agent.Backend.CredentialsTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Backend.Credentials

  setup do
    # Point the store at a throwaway file so tests never touch the real
    # ~/.raxol/providers.json.
    path =
      Path.join(
        System.tmp_dir!(),
        "raxol-creds-#{System.unique_integer([:positive])}.json"
      )

    prev = System.get_env("RAXOL_PROVIDERS")
    System.put_env("RAXOL_PROVIDERS", path)

    on_exit(fn ->
      File.rm(path)

      if prev,
        do: System.put_env("RAXOL_PROVIDERS", prev),
        else: System.delete_env("RAXOL_PROVIDERS")
    end)

    {:ok, path: path}
  end

  describe "path/0" do
    test "honors $RAXOL_PROVIDERS", %{path: path} do
      assert Credentials.path() == path
    end
  end

  describe "put/2 and load/0" do
    test "round-trips an op reference with model" do
      assert :ok =
               Credentials.put(:anthropic,
                 op_ref: "op://Vault/Anthropic/key",
                 model: "claude-x"
               )

      assert %{
               "anthropic" => %{
                 op_ref: "op://Vault/Anthropic/key",
                 model: "claude-x"
               }
             } =
               Credentials.load()
    end

    test "fetch/1 returns a stored entry, :none otherwise" do
      Credentials.put(:openai, op_ref: "op://Vault/OpenAI/key")

      assert {:ok, %{op_ref: "op://Vault/OpenAI/key"}} =
               Credentials.fetch(:openai)

      assert :none = Credentials.fetch(:anthropic)
    end

    test "refuses an entry with no known fields" do
      assert {:error, :empty_entry} = Credentials.put(:openai, foo: "bar")
    end

    test "never persists a raw api_key field" do
      Credentials.put(:openai,
        op_ref: "op://Vault/OpenAI/key",
        api_key: "sk-secret"
      )

      {:ok, entry} = Credentials.fetch(:openai)
      refute Map.has_key?(entry, :api_key)
      refute File.read!(Credentials.path()) =~ "sk-secret"
    end

    # POSIX mode bits: Windows reports 0o666/0o444 whatever chmod asked for,
    # and OperatorFile skips the mode check there by design.
    @tag :unix_only
    test "writes the file with owner-only permissions", %{path: path} do
      Credentials.put(:openai, op_ref: "op://Vault/OpenAI/key")
      %File.Stat{mode: mode} = File.stat!(path)
      # low 9 bits: 0o600 == rw-------
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "delete/1 removes an entry" do
      Credentials.put(:openai, op_ref: "op://Vault/OpenAI/key")
      assert :ok = Credentials.delete(:openai)
      assert :none = Credentials.fetch(:openai)
    end
  end

  describe "load/0 resilience" do
    test "a missing file is an empty map" do
      assert Credentials.load() == %{}
    end

    test "a malformed file is an empty map, not a crash", %{path: path} do
      File.write!(path, "{ not json")
      assert Credentials.load() == %{}
    end

    test "unknown fields are dropped on read", %{path: path} do
      File.write!(
        path,
        Jason.encode!(%{"openai" => %{"op_ref" => "op://v/i/f", "junk" => 1}})
      )

      assert %{"openai" => entry} = Credentials.load()
      assert entry == %{op_ref: "op://v/i/f"}
    end

    # This module names the field atoms, so loading it creates them and an
    # in-VM read could never catch the bug. Read from a fresh BEAM where
    # only Credentials (and what it calls) gets loaded. The child checks that
    # premise first. Both the call and the expected shape stay out of the
    # script's parse/expansion: expanding a remote call loads its module,
    # and parsing a pattern that names the fields creates the atoms.
    test "reads op_ref, model and base_url in a fresh VM that has never seen those atoms",
         %{path: path} do
      File.write!(
        path,
        Jason.encode!(%{
          "openai" => %{"op_ref" => "op://v/i/f", "model" => "m", "base_url" => "http://b"}
        })
      )

      # The running install's launcher, not whatever `elixir` PATH finds.
      elixir = Path.expand("../../bin/elixir", :code.lib_dir(:elixir))
      code_paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])

      script = ~S"""
      for name <- ~w(op_ref model base_url) do
        try do
          String.to_existing_atom(name)
          IO.puts(:stderr, "atom #{name} exists before Credentials.load/0")
          System.halt(2)
        rescue
          ArgumentError -> :ok
        end
      end

      store = apply(Raxol.Agent.Backend.Credentials, :load, [])

      Code.eval_string(
        ~S'''
        case store do
          %{"openai" => %{op_ref: _, model: _, base_url: _}} -> :ok
          other -> IO.puts(:stderr, "unexpected load/0 result: #{inspect(other)}"); System.halt(3)
        end
        ''',
        store: store
      )
      """

      # A file, not `-e`: Windows' elixir.bat cuts a multi-line argument at
      # its first newline.
      script_file = Path.join(tmp_dir("raxol-fresh-vm"), "check.exs")
      File.write!(script_file, script)

      {out, status} =
        System.cmd(elixir, code_paths ++ [script_file],
          env: [{"RAXOL_PROVIDERS", path}],
          cd: System.tmp_dir!(),
          stderr_to_stdout: true
        )

      assert status == 0, out
    end

    # An entry here names the vault item a provider key is read from, so a
    # store another account may rewrite is a store that can redirect
    # `op read`. The resolver falls through to env vars instead.
    @tag :unix_only
    test "a store another account may rewrite grants nothing", %{path: path} do
      File.write!(path, Jason.encode!(%{"openai" => %{"op_ref" => "op://attacker/item/f"}}))
      File.chmod!(path, 0o666)

      log = ExUnit.CaptureLog.capture_log(fn -> assert Credentials.load() == %{} end)

      assert log =~ "mode 0666"
      assert :none = Credentials.fetch(:openai)
    end

    # The read hardening turned into data loss: a refusal folded into `%{}`
    # by `load/0` was written straight back, so one `/login` replaced every
    # other provider reference in the file with the new entry (and chmodded
    # it 600 on the way out). A refused store is still writable by its owner;
    # 0664 is what umask 002 produces.
    @tag :unix_only
    test "a store another account may rewrite is not overwritten", %{path: path} do
      contents = Jason.encode!(%{"openai" => %{"op_ref" => "op://Vault/OpenAI/key"}})
      File.write!(path, contents)
      File.chmod!(path, 0o664)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:group_or_other_writable, 0o664}} =
                 Credentials.put(:anthropic, op_ref: "op://Vault/Anthropic/key")

        assert {:error, {:group_or_other_writable, 0o664}} = Credentials.delete(:openai)
      end)

      assert File.read!(path) == contents
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o664
    end
  end

  describe "read_ref/1" do
    test "rejects a non-op reference" do
      assert {:error, :not_an_op_ref} = Credentials.read_ref("sk-not-a-ref")
    end

    test "op_available?/0 returns a boolean" do
      assert is_boolean(Credentials.op_available?())
    end

    test "an op ref errors cleanly when op is unavailable" do
      # Only deterministic without the op CLI; with op installed the call
      # depends on live vault state, so we just assert the error shape.
      case Credentials.read_ref("op://__raxol_test__/nope/field") do
        {:error, :op_unavailable} -> assert not Credentials.op_available?()
        {:error, _other} -> assert Credentials.op_available?()
      end
    end
  end

  describe "op lookup" do
    @tag :unix_only
    test "ignores an op on a relative PATH entry" do
      # Under the package's own tmp/ so the relative form resolves from the
      # test cwd without changing it.
      relative = Path.join("tmp", "raxol-rel-op-#{System.unique_integer([:positive])}")
      absolute = Path.expand(relative)
      fake_op(absolute, "#!/bin/sh\necho planted\n")
      on_exit(fn -> File.rm_rf!(absolute) end)

      # Positive control: the same directory as an absolute entry is used.
      put_env_restored("PATH", absolute)
      assert Credentials.op_available?()

      System.put_env("PATH", relative)
      refute Credentials.op_available?()
      assert {:error, :op_unavailable} = Credentials.read_ref("op://v/i/f")
    end
  end

  describe "op_status/0" do
    test "returns one of the three known states" do
      assert Credentials.op_status() in [:absent, :not_signed_in, :ok]
    end

    test "is :absent exactly when op is unavailable" do
      if Credentials.op_available?() do
        assert Credentials.op_status() in [:ok, :not_signed_in]
      else
        assert Credentials.op_status() == :absent
      end
    end

    # 126/127 is the shell saying the `op` it found cannot run; telling the
    # user to `op signin` for that sends them after the wrong problem.
    @tag :unix_only
    test "maps an op whoami exit of 126 or 127 to :absent" do
      dir = tmp_dir("raxol-broken-op")
      put_env_restored("PATH", dir)

      for code <- [126, 127] do
        fake_op(dir, "#!/bin/sh\nexit #{code}\n")
        assert Credentials.op_status() == :absent
      end

      # Control: any other failure still reads as signed out.
      fake_op(dir, "#!/bin/sh\nexit 1\n")
      assert Credentials.op_status() == :not_signed_in
    end
  end

  describe "bounded op shell-out" do
    # The fake `op` is a `#!/bin/sh` script on a `:`-separated PATH.
    @describetag :unix_only

    # A fake `op` that hangs stands in for a locked vault: the runner
    # must give up (bounded by RAXOL_OP_TIMEOUT_MS) and kill the child
    # instead of blocking the caller for the child's lifetime.
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "raxol-fake-op-#{System.os_time(:millisecond)}-" <>
            "#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      fake_op = Path.join(dir, "op")
      File.write!(fake_op, "#!/bin/sh\nsleep 60\n")
      File.chmod!(fake_op, 0o755)

      prev_path = System.get_env("PATH")
      prev_timeout = System.get_env("RAXOL_OP_TIMEOUT_MS")
      System.put_env("PATH", dir <> ":" <> (prev_path || ""))
      System.put_env("RAXOL_OP_TIMEOUT_MS", "200")

      on_exit(fn ->
        System.put_env("PATH", prev_path || "")

        if prev_timeout,
          do: System.put_env("RAXOL_OP_TIMEOUT_MS", prev_timeout),
          else: System.delete_env("RAXOL_OP_TIMEOUT_MS")

        File.rm_rf!(dir)
      end)

      :ok
    end

    @tag timeout: 10_000
    test "read_ref times out against a hung op instead of blocking" do
      assert {:error, :op_timeout} =
               Credentials.read_ref("op://vault/item/field")
    end

    @tag timeout: 10_000
    test "op_status reads a hung op as not signed in" do
      assert Credentials.op_status() == :not_signed_in
    end

    @tag timeout: 10_000
    test "a timed-out op leaves no port messages in the caller's mailbox" do
      # An op that flushes output right before hanging: the data message
      # lands in the caller's mailbox and must be drained on timeout —
      # in the TUI the caller is the dispatcher, whose catch-all
      # handle_info would log (and thereby leak) a stranded secret.
      fake_op = System.find_executable("op")
      File.write!(fake_op, "#!/bin/sh\necho leaked-secret\nsleep 60\n")

      assert {:error, :op_timeout} =
               Credentials.read_ref("op://vault/item/field")

      refute_receive {_port, {:data, _leak}}, 50
      refute_receive {_port, {:exit_status, _status}}, 50
    end
  end

  describe "create_item/3" do
    test "refuses an empty key" do
      assert {:error, :empty_key} = Credentials.create_item(:openai, "")
    end

    test "errors when op is unavailable rather than raising" do
      # Deterministic only without op; with op present a live create would
      # mutate a real vault, so we do not exercise the success path here.
      unless Credentials.op_available?() do
        assert {:error, :op_unavailable} =
                 Credentials.create_item(:openai, "sk-x")
      end
    end
  end

  describe "run_executable/3" do
    # With no `:in` the port's stdin pipe never delivers and never closes, so
    # if the `</dev/null` redirect is lost a stdin-reading child blocks until
    # the deadline -- on every host, CI included, not just under a tty. That
    # is the `op item create` hang: `op` waits on an open stdin instead of
    # going to the desktop-app integration.
    #
    # `cat` with no arguments reads stdin to EOF: EOF means it exits at once.
    @tag :unix_only
    test "points the child's stdin at /dev/null, so a stdin-reading child sees EOF" do
      cat = System.find_executable("cat")
      assert cat, "cat is required for this test"

      # `{"", 0}` IS the discriminator: a child still blocked on an open
      # stdin pipe is killed at the 5s deadline and comes back as a timeout
      # error, never as a clean exit. No elapsed-time assertion needed.
      assert {"", 0} = Credentials.run_executable(cat, [], 5_000)
    end

    # The wrapper shell's own stderr (xtrace here; a setlocale warning or a
    # PS4 substitution elsewhere) is merged into the output by
    # :stderr_to_stdout, which for `op read` IS the secret.
    @tag :unix_only
    test "returns only the target's output when SHELLOPTS enables xtrace" do
      put_env_restored("SHELLOPTS", "braceexpand:hashall:interactive-comments:xtrace")
      echo = System.find_executable("echo")

      assert {"hello\n", 0} = Credentials.run_executable(echo, ["hello"], 5_000)
    end

    # bash-as-sh exits 126 for a missing `exec` target, dash 127.
    @tag :unix_only
    test "reports a missing executable as the shell's 126/127, not a raise" do
      missing = Path.join(tmp_dir("raxol-no-exe"), "nope")
      assert {_diagnostic, code} = Credentials.run_executable(missing, [], 5_000)
      assert code in [126, 127]
    end

    @tag :unix_only
    test "returns the child's output and exit status" do
      echo = System.find_executable("echo")
      assert {output, 0} = Credentials.run_executable(echo, ["hello"], 5_000)
      assert String.trim(output) == "hello"
    end

    # The bound is the whole point of the Port runner: a hung `op` must not
    # freeze the caller (the TUI update loop, a test, an ACP turn).
    @tag :unix_only
    test "kills a child that outlives its deadline" do
      sleep = System.find_executable("sleep")

      assert {:error, :op_timeout} =
               Credentials.run_executable(sleep, ["30"], 300)
    end

    # Windows takes the direct-spawn clause of `SpawnedPort.spawn_spec/3`: no
    # wrapper shell, just `:in`, which erts turns into a NUL stdin. `sort`
    # with no file argument reads stdin to EOF, the same discriminator as
    # `cat` above: an open stdin pipe would hold it until the deadline and
    # come back as `{:error, :op_timeout}`, never as a clean `{"", 0}`.
    @tag :windows_only
    test "a stdin-reading child sees EOF on Windows" do
      assert {"", 0} = Credentials.run_executable(system32("sort.exe"), [], 5_000)
    end

    @tag :windows_only
    test "returns the child's output and exit status on Windows" do
      assert {"hello\r\n", 0} =
               Credentials.run_executable(system32("cmd.exe"), ["/c", "echo hello"], 5_000)
    end

    # No wrapper shell to turn a missing target into an exit code: the spawn
    # itself fails, and that must come back as a value, not a raise.
    @tag :windows_only
    test "reports a missing executable as a spawn failure on Windows" do
      missing = Path.join(tmp_dir("raxol-no-exe"), "nope.exe")

      assert {:error, {:op_spawn_failed, :enoent}} =
               Credentials.run_executable(missing, [], 5_000)
    end

    @tag :windows_only
    test "bounds a child that outlives its deadline on Windows" do
      assert {:error, :op_timeout} =
               Credentials.run_executable(system32("PING.EXE"), ["-n", "30", "127.0.0.1"], 300)
    end
  end

  defp put_env_restored(var, value) do
    prev = System.get_env(var)
    System.put_env(var, value)

    on_exit(fn ->
      if prev, do: System.put_env(var, prev), else: System.delete_env(var)
    end)
  end

  # Absolute, so Git-for-Windows' `/usr/bin` lookalikes on the runner's PATH
  # never stand in for the native binary.
  defp system32(exe), do: Path.join([System.fetch_env!("SystemRoot"), "System32", exe])

  defp tmp_dir(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp fake_op(dir, script) do
    File.mkdir_p!(dir)
    op = Path.join(dir, "op")
    File.write!(op, script)
    File.chmod!(op, 0o755)
  end
end
