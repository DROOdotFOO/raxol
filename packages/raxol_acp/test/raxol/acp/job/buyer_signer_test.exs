defmodule Raxol.ACP.Job.BuyerSignerTest do
  @moduledoc """
  End-to-end test that exercises the buyer-side ACP authorization path:
  the riddler-permit2-erc3009 CLI produces a buyer authorization, the
  signature flows through Job.Server.accept_payment/3, and the memo log
  records it byte-for-byte.

  Skipped by default; enable with `mix test --include cli_signer` or by
  setting `RIDDLER_CLI_DIR`.
  """

  use ExUnit.Case, async: false

  import Raxol.ACP.TestSupport.WorkflowSetup

  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.ContractClient.InMemory
  alias Raxol.ACP.Job
  alias Raxol.ACP.Job.Store

  @moduletag :cli_signer

  @canonical_private_key "0x0000000000000000000000000000000000000000000000000000000000000001"
  @buyer "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
  @seller "0xc6E555dfcC47e4A3bfecd6879570044ADc0270ff"
  @deadline 1_900_000_000
  @bootstrap_sig <<0xAA, 0xBB>>

  setup_all do
    case resolve_cli_dir() do
      nil -> {:skip, "riddler CLI not found; set RIDDLER_CLI_DIR"}
      cli_dir -> {:ok, cli_dir: cli_dir}
    end
  end

  setup :with_isolated_workflow_saver

  setup do
    # Terminate any leftover Job.Server children so synthetic ids don't
    # collide with prior runs.
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Job.Supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(Job.Supervisor, pid)
    end

    InMemory.reset()
    Store.clear()
    :ok
  end

  describe "buyer authorization via riddler-permit2-erc3009 CLI" do
    test "erc3009 auth: state advances to :transaction; memo carries the signature",
         %{cli_dir: cli_dir} do
      {job_id, _pid} = start_job_in_negotiation()

      {:ok, result} =
        run_cli(cli_dir, "acp-buyer-auth", [
          {"--job-id", to_string(job_id)},
          {"--buyer", @buyer},
          {"--seller", @seller},
          {"--amount", "1000000"},
          {"--chain", "base"},
          {"--token", "usdc"},
          {"--auth-type", "erc3009"},
          {"--deadline", to_string(@deadline)}
        ])

      assert result["auth_type"] == "erc3009"
      assert result["chain_id"] == 8453
      assert result["buyer"] == @buyer

      signature = hex_to_bytes(result["signature"])

      payload = %{
        "domain" => result["domain"],
        "message" => result["message"],
        "signed_object" => result["signed_object"]
      }

      assert {:ok, :transaction} = Job.Server.accept_payment(job_id, payload, signature)
      assert Job.Server.current_state(job_id) == :transaction

      memos = Job.Server.memos(job_id)
      payment_memo = List.last(memos)
      assert payment_memo.signature == signature
      assert payment_memo.next_phase == :transaction
      assert payment_memo.memo_type == :txhash
    end

    test "permit2 auth: state advances; orderId is deterministic from job_id",
         %{cli_dir: cli_dir} do
      {job_id, _pid} = start_job_in_negotiation()

      {:ok, result} =
        run_cli(cli_dir, "acp-buyer-auth", [
          {"--job-id", to_string(job_id)},
          {"--buyer", @buyer},
          {"--seller", @seller},
          {"--amount", "1000000"},
          {"--chain", "base"},
          {"--token", "usdc"},
          {"--auth-type", "permit2"},
          {"--deadline", to_string(@deadline)}
        ])

      assert result["auth_type"] == "permit2"
      assert result["signed_object"] =~ ~r/^0x[0-9a-f]+$/

      # Re-run with the same job_id: deterministic orderId means the witness
      # struct hash is identical, so the digest is identical too.
      {:ok, result2} =
        run_cli(cli_dir, "acp-buyer-auth", [
          {"--job-id", to_string(job_id)},
          {"--buyer", @buyer},
          {"--seller", @seller},
          {"--amount", "1000000"},
          {"--chain", "base"},
          {"--token", "usdc"},
          {"--auth-type", "permit2"},
          {"--deadline", to_string(@deadline)}
        ])

      assert result["message"]["witness"]["orderId"] ==
               result2["message"]["witness"]["orderId"]

      signature = hex_to_bytes(result["signature"])

      payload = %{
        "domain" => result["domain"],
        "message" => result["message"],
        "signed_object" => result["signed_object"]
      }

      assert {:ok, :transaction} = Job.Server.accept_payment(job_id, payload, signature)
    end
  end

  # -- Helpers --

  defp start_job_in_negotiation do
    {:ok, job_id} = ContractClient.create_job(@seller, @seller, 9_999_999_999)
    {:ok, pid} = Job.Supervisor.start_job(job_id: job_id)

    {:ok, :negotiation} =
      Job.Server.transition(job_id, :accept_request, %{}, @bootstrap_sig)

    {job_id, pid}
  end

  defp run_cli(cwd, subcommand, flags) do
    args =
      ["src/index.js", subcommand] ++
        Enum.flat_map(flags, fn {name, value} -> [name, value] end)

    env = [{"PRIVATE_KEY", @canonical_private_key}]

    case System.cmd("node", args, cd: cwd, env: env, stderr_to_stdout: true) do
      {stdout, 0} ->
        case Regex.run(~r/^RESULT_JSON:\s*(\{.*\})\s*$/m, stdout) do
          [_, json] -> {:ok, Jason.decode!(json)}
          nil -> {:error, {:no_result_json, stdout}}
        end

      {stdout, code} ->
        {:error, {:cli_failed, code, stdout}}
    end
  end

  defp resolve_cli_dir do
    candidates =
      [
        System.get_env("RIDDLER_CLI_DIR"),
        Path.expand("../../../../../../riddler-permit2-erc3009", __DIR__)
      ]
      |> Enum.reject(&is_nil/1)

    Enum.find(candidates, fn dir ->
      File.dir?(dir) and File.exists?(Path.join([dir, "src", "index.js"]))
    end)
  end

  defp hex_to_bytes("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
end
