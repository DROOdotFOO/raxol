defmodule Mix.Tasks.Raxol.Broker.InitTest do
  use ExUnit.Case, async: false

  alias Raxol.Broker.PolicyFile

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    directory =
      Path.join(System.tmp_dir!(), "broker-init-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    previous_cwd = File.cwd!()
    File.cd!(directory)

    on_exit(fn ->
      File.cd!(previous_cwd)
      File.rm_rf!(directory)
      Mix.shell(previous_shell)
    end)

    :ok
  end

  test "noninteractive use requires both flags and writes nothing" do
    Mix.shell(Mix.Shell.IO)

    output =
      ExUnit.CaptureIO.capture_io("", fn ->
        for {args, missing_flag} <- [
              {[], "--max-notional"},
              {["--max-notional", "1000"], "--daily-cap"}
            ] do
          assert_raise Mix.Error, ~r/#{missing_flag} is required/, fn -> run_task(args) end
          assert_directory_entries([])
        end
      end)

    assert output == ""
  end

  test "prompts for both missing caps and writes a loadable policy" do
    send(self(), {:mix_shell_input, :prompt, "1000.50\n"})
    send(self(), {:mix_shell_input, :prompt, "5000\n"})

    run_task([])

    assert_received {:mix_shell, :prompt, ["Maximum notional per order (required):"]}
    assert_received {:mix_shell, :prompt, ["Daily notional cap (required):"]}
    assert {:ok, policy} = PolicyFile.load()
    assert Decimal.equal?(policy[:max_notional_per_order], Decimal.new("1000.50"))
    assert Decimal.equal?(policy[:daily_notional_cap], Decimal.new("5000"))
    assert_directory_entries([PolicyFile.filename()])
  end

  test "invalid prompt input writes nothing" do
    send(self(), {:mix_shell_input, :prompt, "not-a-decimal"})

    assert_raise Mix.Error, ~r/--max-notional must be a positive decimal/, fn ->
      run_task([])
    end

    assert_received {:mix_shell, :prompt, ["Maximum notional per order (required):"]}
    refute_received {:mix_shell, :prompt, ["Daily notional cap (required):"]}
    assert_directory_entries([])
  end

  test "EOF while prompting raises and writes nothing" do
    send(self(), {:mix_shell_input, :prompt, :eof})

    assert_raise Mix.Error, ~r/--max-notional prompt ended before an answer/, fn ->
      run_task([])
    end

    assert_received {:mix_shell, :prompt, ["Maximum notional per order (required):"]}
    refute_received {:mix_shell, :prompt, ["Daily notional cap (required):"]}
    assert_directory_entries([])
  end

  test "writes a policy from flags that PolicyFile accepts" do
    run_task(["--max-notional", "1000.50", "--daily-cap", "5000"])

    assert {:ok, policy} = PolicyFile.load()
    assert Decimal.equal?(policy[:max_notional_per_order], Decimal.new("1000.50"))
    assert Decimal.equal?(policy[:daily_notional_cap], Decimal.new("5000"))
    assert_directory_entries([PolicyFile.filename()])
  end

  test "generated policy has no group or other permissions" do
    run_task(["--max-notional", "1000.50", "--daily-cap", "5000"])

    assert {:ok, stat} = File.stat(PolicyFile.filename())
    assert Bitwise.band(stat.mode, 0o077) == 0
  end

  if match?({:unix, _}, :os.type()) do
    test "refuses publication from an untrusted directory and removes staging files" do
      File.chmod!(".", 0o777)

      assert_raise Mix.Error, ~r/refusing to publish untrusted staging file/, fn ->
        run_task(["--max-notional", "1000.50", "--daily-cap", "5000"])
      end

      assert_directory_entries([])
    end
  end

  test "failed policy validation leaves no partial or staging file" do
    assert_raise Mix.Error, ~r/invalid broker policy/, fn ->
      run_task(["--max-notional", "-1", "--daily-cap", "5000"])
    end

    assert_directory_entries([])
  end

  test "refuses to overwrite an existing destination and leaves no staging file" do
    File.write!(PolicyFile.filename(), "original policy")

    assert_raise Mix.Error, ~r/refusing to overwrite broker.policy.exs/, fn ->
      run_task(["--max-notional", "1000", "--daily-cap", "5000"])
    end

    assert File.read!(PolicyFile.filename()) == "original policy"
    assert_directory_entries([PolicyFile.filename()])
  end

  test "refuses to replace an existing symlink" do
    File.write!("sentinel", "unchanged")
    File.ln_s!("sentinel", PolicyFile.filename())

    assert_raise Mix.Error, ~r/refusing to overwrite broker.policy.exs/, fn ->
      run_task(["--max-notional", "1000", "--daily-cap", "5000"])
    end

    assert File.read_link(PolicyFile.filename()) == {:ok, "sentinel"}
    assert File.read!("sentinel") == "unchanged"
    assert_directory_entries([PolicyFile.filename(), "sentinel"])
  end

  defp assert_directory_entries(expected) do
    assert Enum.sort(File.ls!(".")) == Enum.sort(expected)
  end

  defp run_task(args) do
    Mix.Task.reenable("raxol.broker.init")
    Mix.Tasks.Raxol.Broker.Init.run(args)
  end
end
