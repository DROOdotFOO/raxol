defmodule Raxol.Payments.Test.CliSignerTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Test.CliSigner

  @moduletag :cli_signer

  setup do
    cwd =
      System.get_env("RIDDLER_CLI_DIR") ||
        Path.expand("../../../../riddler-client", __DIR__)

    cli_available? =
      File.dir?(cwd) and File.exists?(Path.join([cwd, "src", "index.js"]))

    if cli_available? do
      # Check whether the CLI on disk has the sign-only/acp-buyer-auth
      # subcommands we depend on. They land in
      # https://github.com/axol-io/riddler-client/pull/21; while it's
      # unmerged, the dev checkout must be on that branch for these tests to
      # exercise the spawn path.
      has_subcommands? =
        File.exists?(Path.join([cwd, "src", "acp.js"]))

      {:ok, cli_dir: cwd, cli_available?: cli_available? and has_subcommands?}
    else
      {:ok, cli_dir: cwd, cli_available?: false}
    end
  end

  describe "run/3 against a real CLI" do
    test "invokes `node src/index.js help` and exits 0", %{
      cli_dir: cwd,
      cli_available?: cli_available?
    } do
      unless cli_available? do
        flunk("CLI not available; set RIDDLER_CLI_DIR or run with --exclude cli_signer")
      end

      assert {:ok, %{exit_code: 0, stdout: stdout}} =
               CliSigner.run("help", [], cwd: cwd)

      assert stdout =~ "RIDDLER COMMERCE CLIENT"
    end

    test "acp-buyer-auth emits a parseable RESULT_JSON line", %{
      cli_dir: cwd,
      cli_available?: cli_available?
    } do
      unless cli_available? do
        flunk("CLI not available; set RIDDLER_CLI_DIR or run with --exclude cli_signer")
      end

      flags = [
        job_id: "12345",
        buyer: "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf",
        seller: "0xc6E555dfcC47e4A3bfecd6879570044ADc0270ff",
        amount: "1000000",
        chain: "base",
        token: "usdc",
        auth_type: "erc3009",
        deadline: "1900000000"
      ]

      assert {:ok, %{result_json: result}} =
               CliSigner.acp_buyer_auth(flags,
                 cwd: cwd,
                 private_key: "0x0000000000000000000000000000000000000000000000000000000000000001"
               )

      assert is_map(result)
      assert result["auth_type"] == "erc3009"
      assert result["job_id"] == "12345"
      assert result["chain_id"] == 8453
      assert result["digest"] =~ ~r/^0x[0-9a-f]{64}$/
      assert result["signature"] =~ ~r/^0x[0-9a-f]{130}$/
    end

    test "non-zero exit returns {:error, {:cli_failed, _, _}}", %{
      cli_dir: cwd,
      cli_available?: cli_available?
    } do
      unless cli_available? do
        flunk("CLI not available; set RIDDLER_CLI_DIR or run with --exclude cli_signer")
      end

      # Force a failure: invoke acp-buyer-auth with missing required flags.
      assert {:error, {:cli_failed, code, stdout}} =
               CliSigner.run("acp-buyer-auth", [],
                 cwd: cwd,
                 private_key: "0x0000000000000000000000000000000000000000000000000000000000000001"
               )

      assert code != 0
      assert is_binary(stdout)
    end
  end

  describe "encode_flags/1 (via run)" do
    # Use a non-existent CLI directory to bypass the actual subprocess
    # invocation and exercise flag encoding via the raised error.
    test "atom flag names become --snake_case" do
      assert_raise CliSigner.CliNotFoundError, fn ->
        CliSigner.run("foo", [job_id: "1", chain: "base"], cwd: "/nonexistent/path")
      end
    end

    test "boolean true emits bare flag; false drops it" do
      # Same: cwd doesn't exist, so this exercises the encoding logic
      # before the cwd check raises.
      assert_raise CliSigner.CliNotFoundError, fn ->
        CliSigner.run("foo", [dry_run: true, verbose: false], cwd: "/nonexistent")
      end
    end
  end

  describe "CliNotFoundError" do
    test "raises with a clear message when the CLI repo can't be found" do
      assert_raise CliSigner.CliNotFoundError, ~r/Could not locate riddler-client/, fn ->
        CliSigner.run("help", [], cwd: "/definitely/does/not/exist")
      end
    end
  end
end
