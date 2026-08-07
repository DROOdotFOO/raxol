defmodule Raxol.Agent.Backend.CliTest do
  # async: false — resolve_executor/2 reads real env vars and the stored
  # provider file; setup swaps both for a hermetic snapshot.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Raxol.Agent.Backend.Cli
  alias Raxol.Agent.ExecutorConfig

  # Every env var the resolver reads. Cleared in setup so a developer's real
  # ANTHROPIC_API_KEY (etc.) can't leak into these assertions.
  @managed_env ~w(
    ANTHROPIC_API_KEY ANTHROPIC_MODEL OPENAI_API_KEY OPENAI_MODEL
    KIMI_API_KEY MOONSHOT_API_KEY KIMI_MODEL OPENROUTER_API_KEY OPENROUTER_MODEL
    LONGCAT_API_KEY LONGCAT_MODEL PROTON_ACCESS_TOKEN OLLAMA_MODEL
    AI_API_KEY AI_BASE_URL AI_MODEL
    RAXOL_ANTHROPIC_OP RAXOL_OPENAI_OP RAXOL_KIMI_OP RAXOL_OPENROUTER_OP
    RAXOL_LONGCAT_OP RAXOL_LUMO_OP RAXOL_OLLAMA_OP RAXOL_LM_STUDIO_OP
    RAXOL_LLM7_OP RAXOL_MOCK_OP
  )

  setup do
    saved = Map.new(@managed_env, fn key -> {key, System.get_env(key)} end)
    Enum.each(@managed_env, &System.delete_env/1)

    store =
      Path.join(
        System.tmp_dir!(),
        "raxol-cli-#{System.unique_integer([:positive])}.json"
      )

    prev_store = System.get_env("RAXOL_PROVIDERS")
    System.put_env("RAXOL_PROVIDERS", store)

    on_exit(fn ->
      File.rm(store)

      if prev_store,
        do: System.put_env("RAXOL_PROVIDERS", prev_store),
        else: System.delete_env("RAXOL_PROVIDERS")

      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, val} -> System.put_env(key, val)
      end)
    end)

    :ok
  end

  describe "flag/2 name resolution" do
    test "returns {:ok, nil} when neither flag is given" do
      assert {:ok, nil} = Cli.flag([], "raxol.code")
    end

    test "resolves the canonical --backend flag" do
      assert {:ok, :anthropic} = Cli.flag([backend: "anthropic"], "raxol.code")
    end

    test "resolves the deprecated --harness alias" do
      assert {:ok, :anthropic} =
               capture_result(fn ->
                 Cli.flag([harness: "anthropic"], "raxol.code")
               end)
    end

    test "--backend wins when both flags are given" do
      assert {:ok, :openai} =
               capture_result(fn ->
                 Cli.flag(
                   [backend: "openai", harness: "anthropic"],
                   "raxol.code"
                 )
               end)
    end

    test "returns an error with the supported list for an unknown name" do
      assert {:error, message} = Cli.flag([backend: "nonsense"], "raxol.code")

      assert message =~ ~s(unknown backend "nonsense")
      assert message =~ "mock"
    end
  end

  describe "flag/2 stderr notices" do
    test "warns when the deprecated alias is used" do
      stderr =
        capture_io(:stderr, fn ->
          Cli.flag([harness: "mock"], "raxol.code")
        end)

      assert stderr =~ "raxol.code: --harness is deprecated; use --backend"
    end

    test "warns when both flags are given" do
      stderr =
        capture_io(:stderr, fn ->
          Cli.flag([backend: "mock", harness: "openai"], "raxol.code")
        end)

      assert stderr =~ "raxol.code: both --backend and --harness given"
    end

    test "canonical --backend emits nothing to stderr" do
      assert capture_io(:stderr, fn ->
               Cli.flag([backend: "mock"], "raxol.code")
             end) == ""
    end

    test "prog: nil suppresses every notice (protects the raxol.p JSONL stream)" do
      # Even the deprecated-alias and both-given paths must stay silent so a
      # strict JSONL consumer of raxol.p's stderr is never handed a plain line.
      assert capture_io(:stderr, fn -> Cli.flag([harness: "mock"], nil) end) ==
               ""

      assert capture_io(:stderr, fn ->
               Cli.flag([backend: "mock", harness: "openai"], nil)
             end) ==
               ""
    end
  end

  describe "resolve_executor/2" do
    test "nothing configured and no flag: an actionable error, not a default" do
      assert {:error, message} = Cli.resolve_executor([], nil)

      assert message =~ "no provider configured"
      assert message =~ "mix raxol.setup"
      assert message =~ "--backend lm_studio"
    end

    test "an explicit keyless backend pins the local server, no credential needed" do
      assert {:ok, %ExecutorConfig{} = executor, :explicit} =
               Cli.resolve_executor([backend: "lm_studio"], nil)

      assert executor.backend == :lm_studio
      assert executor.auth == %{}
    end

    test "an explicit keyed backend without a credential names the fix" do
      assert {:error, message} =
               Cli.resolve_executor([backend: "anthropic"], nil)

      assert message =~ "no credential resolved for anthropic"
      assert message =~ "mix raxol.setup --provider anthropic"
    end

    test "a provider env var auto-detects into a ready executor" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant")

      assert {:ok, %ExecutorConfig{} = executor, :env} =
               Cli.resolve_executor([], nil)

      assert executor.backend == :anthropic
      assert executor.auth == %{api_key: "sk-ant"}
    end

    test "an explicit --api-key wins over the env var" do
      System.put_env("ANTHROPIC_API_KEY", "sk-env")

      assert {:ok, executor, :explicit} =
               Cli.resolve_executor(
                 [backend: "anthropic", api_key: "sk-flag"],
                 nil
               )

      assert executor.auth == %{api_key: "sk-flag"}
    end

    test "the model opt flows into the executor" do
      assert {:ok, executor, :explicit} =
               Cli.resolve_executor([backend: "mock", model: "m-test"], nil)

      assert executor.model == "m-test"
    end

    test "an unknown backend name surfaces the flag error" do
      assert {:error, message} =
               Cli.resolve_executor([backend: "nonsense"], nil)

      assert message =~ ~s(unknown backend "nonsense")
    end
  end

  # Run while swallowing any deprecation notice the case under test expects.
  defp capture_result(fun) do
    parent = self()
    capture_io(:stderr, fn -> send(parent, {:result, fun.()}) end)

    receive do
      {:result, result} -> result
    after
      0 -> flunk("flag/2 did not return")
    end
  end
end
