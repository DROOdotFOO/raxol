defmodule Raxol.Agent.SetupTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Backend.Credentials
  alias Raxol.Agent.Setup

  # Provider env keys the resolver reads; cleared so the store is the only
  # source of truth for these tests (mirrors app_login_test's isolation).
  @managed_env ~w(
    ANTHROPIC_API_KEY OPENAI_API_KEY KIMI_API_KEY MOONSHOT_API_KEY
    OPENROUTER_API_KEY LONGCAT_API_KEY PROTON_ACCESS_TOKEN
    AI_API_KEY AI_BASE_URL AI_MODEL
  )

  setup do
    saved = Map.new(@managed_env, fn key -> {key, System.get_env(key)} end)
    Enum.each(@managed_env, &System.delete_env/1)

    store =
      Path.join(
        System.tmp_dir!(),
        "raxol-setup-#{System.unique_integer([:positive])}.json"
      )

    prev = System.get_env("RAXOL_PROVIDERS")
    System.put_env("RAXOL_PROVIDERS", store)

    on_exit(fn ->
      File.rm(store)

      if prev,
        do: System.put_env("RAXOL_PROVIDERS", prev),
        else: System.delete_env("RAXOL_PROVIDERS")

      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    # A validator that never touches the network.
    %{ok_validator: fn _harness -> :valid end}
  end

  describe "connect_ref/3" do
    test "stores the op reference and validates", %{ok_validator: v} do
      assert {:ok, :anthropic, :valid} =
               Setup.connect_ref(
                 "anthropic",
                 %{
                   op_ref: "op://Vault/Anthropic/key",
                   model: "claude-sonnet-5"
                 },
                 validator: v
               )

      assert {:ok, entry} = Credentials.fetch(:anthropic)
      assert entry.op_ref == "op://Vault/Anthropic/key"
      assert entry.model == "claude-sonnet-5"
    end

    test "surfaces a rejected credential from the validator" do
      assert {:ok, :openai, {:rejected, 401}} =
               Setup.connect_ref(
                 :openai,
                 %{op_ref: "op://Vault/OpenAI/key"},
                 validator: fn _ -> {:rejected, 401} end
               )
    end

    test "rejects a non-op reference and stores nothing", %{ok_validator: v} do
      assert {:error, :not_an_op_ref} =
               Setup.connect_ref(:openai, %{op_ref: "sk-raw-key"}, validator: v)

      assert Credentials.fetch(:openai) == :none
    end

    test "rejects an unknown provider" do
      assert {:error, {:unknown_provider, "nope"}} =
               Setup.connect_ref("nope", %{op_ref: "op://V/I/f"})
    end
  end

  describe "connect_key/3" do
    test "creates a 1Password item, stores the returned reference, validates" do
      creator = fn :openai, "sk-live", _opts ->
        {:ok, "op://Private/abc/credential"}
      end

      assert {:ok, :openai, "op://Private/abc/credential", :valid} =
               Setup.connect_key(:openai, "sk-live",
                 creator: creator,
                 validator: fn _ -> :valid end
               )

      assert {:ok, %{op_ref: "op://Private/abc/credential"}} =
               Credentials.fetch(:openai)
    end

    test "surfaces a creator failure (no op CLI) and stores nothing" do
      creator = fn _h, _k, _o -> {:error, :op_unavailable} end

      assert {:error, :op_unavailable} =
               Setup.connect_key(:openai, "sk-live", creator: creator)

      assert Credentials.fetch(:openai) == :none
    end

    # The browser sign-in raises 1Password's prompt while the user is still
    # looking at a browser tab, so it needs to widen the `op` budget. Losing
    # that race discards a key the provider already minted.
    test "passes :vault and :timeout_ms through to the creator" do
      caller = self()

      creator = fn _harness, _key, opts ->
        send(caller, {:creator_opts, opts})
        {:ok, "op://Private/abc/credential"}
      end

      Setup.connect_key(:openai, "sk-live",
        creator: creator,
        validator: fn _ -> :valid end,
        vault: "Employee",
        timeout_ms: 120_000
      )

      assert_receive {:creator_opts, opts}
      assert Keyword.fetch!(opts, :vault) == "Employee"
      assert Keyword.fetch!(opts, :timeout_ms) == 120_000
    end
  end

  describe "remove/1" do
    test "deletes a stored reference", %{ok_validator: v} do
      {:ok, :kimi, _} =
        Setup.connect_ref(:kimi, %{op_ref: "op://V/Kimi/key"}, validator: v)

      assert {:ok, :kimi} = Setup.remove(:kimi)
      assert Credentials.fetch(:kimi) == :none
    end
  end

  describe "status/0" do
    test "returns the op state and a provider list" do
      status = Setup.status()
      assert Map.has_key?(status, :op)
      assert is_list(status.providers)
      assert Enum.all?(status.providers, &Map.has_key?(&1, :harness))
    end
  end
end
