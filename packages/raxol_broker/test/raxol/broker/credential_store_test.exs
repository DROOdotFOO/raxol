defmodule Raxol.Broker.CredentialStoreTest do
  @moduledoc """
  The encrypted credential file, written and read for real in a temp
  directory. Only the key provider is swapped for an in-memory one.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias Raxol.Agent.Auth.Credential
  alias Raxol.Broker.CredentialStore
  alias Raxol.Broker.Test.MemoryKeys

  @access "fake-access-token-store-00001"
  @refresh "fake-refresh-token-store-00001"
  @uuid "00000000-0000-4000-8000-00000000fa4e"

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    dir = Path.join(dir, "broker")
    path = Path.join(dir, "robinhood.credential")
    opts = [path: path, key_provider: {MemoryKeys, agent: MemoryKeys.start()}]
    {:ok, dir: dir, path: path, opts: opts}
  end

  defp credential do
    %Credential{
      provider: :robinhood,
      issuer: "https://agent.robinhood.com/mcp/trading",
      client_id: "FAKECLIENTID000000000000000000000000TEST",
      access_token: @access,
      refresh_token: @refresh,
      expires_at: ~U[2026-10-12 12:00:00Z],
      scope: "internal",
      user_uuid: @uuid
    }
  end

  test "round-trips a credential", %{opts: opts} do
    assert :ok = CredentialStore.put(credential(), opts)
    assert {:ok, credential()} == CredentialStore.fetch(opts)
  end

  test "the file holds no token bytes and is mode 0600 in a 0700 directory", %{
    path: path,
    dir: dir,
    opts: opts
  } do
    :ok = CredentialStore.put(credential(), opts)
    raw = File.read!(path)

    refute raw =~ @access
    refute raw =~ @refresh
    refute raw =~ @uuid
    refute raw =~ Base.encode64(@access)

    assert (File.lstat!(path).mode &&& 0o777) == 0o600
    assert (File.lstat!(dir).mode &&& 0o777) == 0o700
  end

  test "replaces an existing credential atomically and leaves no staging file", %{
    dir: dir,
    opts: opts
  } do
    :ok = CredentialStore.put(credential(), opts)
    rotated = %{credential() | refresh_token: "fake-refresh-token-store-00002"}
    :ok = CredentialStore.put(rotated, opts)

    assert {:ok, ^rotated} = CredentialStore.fetch(opts)
    assert File.ls!(dir) == ["robinhood.credential"]
  end

  test "each write uses a fresh nonce", %{path: path, opts: opts} do
    :ok = CredentialStore.put(credential(), opts)
    first = File.read!(path)
    :ok = CredentialStore.put(credential(), opts)

    refute File.read!(path) == first
  end

  test "refuses to write through a symlink at the target", %{dir: dir, path: path, opts: opts} do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    elsewhere = Path.join(dir, "elsewhere")
    File.write!(elsewhere, "")
    File.ln_s!(elsewhere, path)

    assert {:error, {:untrusted_file, :symlink}} = CredentialStore.put(credential(), opts)
    assert File.read!(elsewhere) == ""
  end

  test "refuses to read a symlink", %{dir: dir, path: path, opts: opts} do
    :ok = CredentialStore.put(credential(), opts)
    moved = Path.join(dir, "moved")
    File.rename!(path, moved)
    File.ln_s!(moved, path)

    assert {:error, {:untrusted_file, :symlink}} = CredentialStore.fetch(opts)
  end

  test "refuses a file others can read", %{path: path, opts: opts} do
    :ok = CredentialStore.put(credential(), opts)
    File.chmod!(path, 0o644)

    assert {:error, {:untrusted_file, :mode}} = CredentialStore.fetch(opts)
  end

  test "a missing file is :not_found", %{opts: opts} do
    assert {:error, :not_found} = CredentialStore.fetch(opts)
  end

  describe "a damaged file is a tagged error, never a raise" do
    setup %{path: path, opts: opts} do
      :ok = CredentialStore.put(credential(), opts)
      {:ok, envelope: path |> File.read!() |> Jason.decode!()}
    end

    defp rewrite(path, contents) do
      File.write!(path, contents)
      File.chmod!(path, 0o600)
    end

    test "truncated", %{path: path, opts: opts} do
      raw = File.read!(path)
      rewrite(path, binary_part(raw, 0, div(byte_size(raw), 2)))

      assert {:error, :corrupt_store} = CredentialStore.fetch(opts)
    end

    test "empty", %{path: path, opts: opts} do
      rewrite(path, "")
      assert {:error, :corrupt_store} = CredentialStore.fetch(opts)
    end

    test "malformed", %{path: path, opts: opts} do
      rewrite(path, ~s({"v":1,"nonce":"!!","ct":3}))
      assert {:error, :corrupt_store} = CredentialStore.fetch(opts)
    end

    test "tampered ciphertext", %{path: path, opts: opts, envelope: envelope} do
      <<first, rest::binary>> = Base.decode64!(envelope["ct"])
      tampered = Map.put(envelope, "ct", Base.encode64(<<bxor(first, 1), rest::binary>>))
      rewrite(path, Jason.encode!(tampered))

      assert {:error, :corrupt_store} = CredentialStore.fetch(opts)
    end

    test "short tag", %{path: path, opts: opts, envelope: envelope} do
      short = Map.put(envelope, "tag", Base.encode64(<<0::64>>))
      rewrite(path, Jason.encode!(short))

      assert {:error, :corrupt_store} = CredentialStore.fetch(opts)
    end

    # The version is bound into the AAD, so relabelling a v1 envelope cannot
    # make another decoder accept it; an unknown version is refused outright.
    test "unknown version", %{path: path, opts: opts, envelope: envelope} do
      rewrite(path, Jason.encode!(Map.put(envelope, "v", 2)))
      assert {:error, {:unsupported_version, 2}} = CredentialStore.fetch(opts)
    end

    test "oversized", %{path: path, opts: opts} do
      rewrite(path, String.duplicate("a", 70_000))
      assert {:error, :corrupt_store} = CredentialStore.fetch(opts)
    end

    test "a different key", %{opts: opts} do
      other = Keyword.put(opts, :key_provider, {MemoryKeys, agent: MemoryKeys.start()})
      assert {:error, :key_missing} = CredentialStore.fetch(other)

      {:ok, _key} = MemoryKeys.create_key(agent: elem(other[:key_provider], 1)[:agent])
      assert {:error, :corrupt_store} = CredentialStore.fetch(other)
    end
  end

  test "an unavailable key store writes nothing", %{path: path} do
    opts = [
      path: path,
      key_provider: {Raxol.Broker.KeyProvider.Keychain, executable: "/nonexistent/security"}
    ]

    assert {:error, {:keychain_unavailable, :no_security_cli}} =
             CredentialStore.put(credential(), opts)

    refute File.exists?(path)
  end
end
