defmodule Raxol.Broker.KeyProvider.KeychainTest do
  @moduledoc """
  The keychain provider driven against a stand-in `security` executable that
  keeps the item in a file and logs every argv it is given -- the real
  binary would write to the user's login keychain. What is under test is the
  provider's half: the key travels over stdin, never argv, and an existing
  item is never replaced.
  """
  use ExUnit.Case, async: true

  alias Raxol.Broker.KeyProvider.Keychain

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    store = Path.join(dir, "item")
    log = Path.join(dir, "argv.log")
    exe = Path.join(dir, "security")

    File.write!(exe, """
    #!/bin/sh
    echo "$@" >> '#{log}'
    case "$1" in
      find-generic-password)
        if [ -f '#{store}' ]; then cat '#{store}'; exit 0; else exit 44; fi ;;
      -i)
        read line
        echo "$line" | grep -q '^add-generic-password ' || exit 1
        key=$(echo "$line" | sed -n 's/.* -w \\([0-9a-f]*\\).*/\\1/p')
        if [ -f '#{store}' ]; then exit 45; fi
        printf '%s\\n' "$key" > '#{store}'
        exit 0 ;;
    esac
    exit 1
    """)

    File.chmod!(exe, 0o700)
    {:ok, opts: [executable: exe], log: log, store: store}
  end

  test "no key yet is :none", %{opts: opts} do
    assert :none = Keychain.load_key(opts)
  end

  test "creates a 256-bit key without ever putting it on argv", %{opts: opts, log: log} do
    assert {:ok, <<_::256>> = key} = Keychain.create_key(opts)
    assert {:ok, ^key} = Keychain.load_key(opts)

    argv = File.read!(log)
    refute argv =~ Base.encode16(key, case: :lower)
    refute argv =~ Base.encode16(key)
    refute argv =~ Base.encode64(key)
  end

  test "never replaces a key another writer stored first", %{opts: opts} do
    assert {:ok, first} = Keychain.create_key(opts)
    assert {:ok, ^first} = Keychain.create_key(opts)
  end

  test "a malformed stored value is refused, not used", %{opts: opts, store: store} do
    File.write!(store, "not-hex\n")
    assert {:error, {:keychain_unavailable, :malformed_key}} = Keychain.load_key(opts)
  end

  test "a missing security binary is keychain_unavailable" do
    assert {:error, {:keychain_unavailable, :no_security_cli}} =
             Keychain.load_key(executable: "/nonexistent/security")
  end
end
