defmodule Raxol.Agent.Backend.CredentialsTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Backend.Credentials

  setup do
    # Point the store at a throwaway file so tests never touch the real
    # ~/.raxol/providers.json.
    path = Path.join(System.tmp_dir!(), "raxol-creds-#{System.unique_integer([:positive])}.json")
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
               Credentials.put(:anthropic, op_ref: "op://Vault/Anthropic/key", model: "claude-x")

      assert %{"anthropic" => %{op_ref: "op://Vault/Anthropic/key", model: "claude-x"}} =
               Credentials.load()
    end

    test "fetch/1 returns a stored entry, :none otherwise" do
      Credentials.put(:openai, op_ref: "op://Vault/OpenAI/key")
      assert {:ok, %{op_ref: "op://Vault/OpenAI/key"}} = Credentials.fetch(:openai)
      assert :none = Credentials.fetch(:anthropic)
    end

    test "refuses an entry with no known fields" do
      assert {:error, :empty_entry} = Credentials.put(:openai, foo: "bar")
    end

    test "never persists a raw api_key field" do
      Credentials.put(:openai, op_ref: "op://Vault/OpenAI/key", api_key: "sk-secret")
      {:ok, entry} = Credentials.fetch(:openai)
      refute Map.has_key?(entry, :api_key)
      refute File.read!(Credentials.path()) =~ "sk-secret"
    end

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
      File.write!(path, Jason.encode!(%{"openai" => %{"op_ref" => "op://v/i/f", "junk" => 1}}))
      assert %{"openai" => entry} = Credentials.load()
      assert entry == %{op_ref: "op://v/i/f"}
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
  end

  describe "create_item/3" do
    test "refuses an empty key" do
      assert {:error, :empty_key} = Credentials.create_item(:openai, "")
    end

    test "errors when op is unavailable rather than raising" do
      # Deterministic only without op; with op present a live create would
      # mutate a real vault, so we do not exercise the success path here.
      unless Credentials.op_available?() do
        assert {:error, :op_unavailable} = Credentials.create_item(:openai, "sk-x")
      end
    end
  end
end
