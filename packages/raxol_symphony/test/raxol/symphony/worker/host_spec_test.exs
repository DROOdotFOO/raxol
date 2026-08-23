defmodule Raxol.Symphony.Worker.HostSpecTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.Worker.HostSpec

  describe "normalize/1" do
    test "a bare host string yields a spec with no user" do
      assert {:ok, %HostSpec{host: "build-1", user: nil, port: nil}} =
               HostSpec.normalize("build-1")
    end

    test "a user@host string splits user and host" do
      assert {:ok, %HostSpec{host: "build-2", user: "ci"}} =
               HostSpec.normalize("ci@build-2")
    end

    test "surrounding whitespace is trimmed" do
      assert {:ok, %HostSpec{host: "build-3", user: "ci"}} =
               HostSpec.normalize("  ci@build-3  ")
    end

    test "a map carries all optional fields" do
      raw = %{
        host: "build-4",
        user: "ci",
        port: 2222,
        identity_file: "~/.ssh/id_ci",
        workspace_root: "/var/lib/symphony"
      }

      assert {:ok,
              %HostSpec{
                host: "build-4",
                user: "ci",
                port: 2222,
                identity_file: "~/.ssh/id_ci",
                workspace_root: "/var/lib/symphony"
              }} = HostSpec.normalize(raw)
    end

    test "string keys are tolerated (directly-built config)" do
      assert {:ok, %HostSpec{host: "build-5", user: "ci", port: 22}} =
               HostSpec.normalize(%{
                 "host" => "build-5",
                 "user" => "ci",
                 "port" => 22
               })
    end

    test "blank/absent optional fields normalize to nil" do
      assert {:ok, %HostSpec{host: "h", user: nil, port: nil, identity_file: nil}} =
               HostSpec.normalize(%{
                 host: "h",
                 user: "",
                 port: 0,
                 identity_file: ""
               })
    end

    test "an already-built spec passes through" do
      spec = %HostSpec{host: "h", user: "u"}
      assert {:ok, ^spec} = HostSpec.normalize(spec)
    end

    test "rejects an empty string, a userless '@host', a mapless host, and non-string/map" do
      assert {:error, {:invalid_ssh_host, ""}} = HostSpec.normalize("")

      assert {:error, {:invalid_ssh_host, "@build"}} =
               HostSpec.normalize("@build")

      assert {:error, {:invalid_ssh_host, %{user: "ci"}}} =
               HostSpec.normalize(%{user: "ci"})

      assert {:error, {:invalid_ssh_host, 42}} = HostSpec.normalize(42)
    end

    test "rejects shell-metacharacter and flag-injection host/user tokens" do
      # These would break out of a later `ssh` invocation (transport #743).
      for bad <- [
            "build; rm -rf /",
            "build`whoami`",
            "build$(id)",
            "a b",
            "build|nc",
            "-oProxyCommand=evil",
            "build\nx"
          ] do
        assert {:error, {:invalid_ssh_host, ^bad}} = HostSpec.normalize(bad),
               "expected #{inspect(bad)} to be rejected"
      end

      assert {:error, {:invalid_ssh_host, _}} =
               HostSpec.normalize(%{host: "ok", user: "-oX"})

      assert {:error, {:invalid_ssh_host, _}} =
               HostSpec.normalize(%{
                 host: "ok",
                 identity_file: "/tmp/k; rm -rf /"
               })

      # A directly-built struct cannot smuggle a dangerous host past normalize.
      assert {:error, {:invalid_ssh_host, _}} =
               HostSpec.normalize(%HostSpec{host: "build; rm"})
    end

    test "accepts ordinary hostnames, IPv4, and safe path fields" do
      assert {:ok, _} = HostSpec.normalize("build-1.internal")
      assert {:ok, _} = HostSpec.normalize("ci@10.0.0.5")

      assert {:ok,
              %HostSpec{
                identity_file: "~/.ssh/id_ci",
                workspace_root: "/var/lib/symphony"
              }} =
               HostSpec.normalize(%{
                 host: "b",
                 identity_file: "~/.ssh/id_ci",
                 workspace_root: "/var/lib/symphony"
               })
    end

    test "a leading-dash path can never be read as an ssh flag" do
      for field <- [:identity_file, :workspace_root, :known_hosts] do
        assert {:error, {:invalid_ssh_host, _}} =
                 HostSpec.normalize(%{:host => "ok", field => "-Fmalicious"}),
               "expected leading-dash #{field} to be rejected"
      end
    end
  end

  describe "host-key policy" do
    test "defaults to accept_new with no known_hosts (current behavior)" do
      assert {:ok, %HostSpec{strict_host_key_checking: :accept_new, known_hosts: nil}} =
               HostSpec.normalize("build-1")

      assert {:ok, %HostSpec{strict_host_key_checking: :accept_new}} =
               HostSpec.normalize(%HostSpec{host: "build-1"})
    end

    test "accepts the three valid modes from string and atom inputs" do
      for {input, mode} <- [
            {"yes", :yes},
            {"accept_new", :accept_new},
            {"accept-new", :accept_new},
            {"no", :no},
            {:yes, :yes},
            {:no, :no}
          ] do
        assert {:ok, %HostSpec{strict_host_key_checking: ^mode}} =
                 HostSpec.normalize(%{host: "h", strict_host_key_checking: input}),
               "expected #{inspect(input)} -> #{inspect(mode)}"
      end
    end

    test "carries a known_hosts path through" do
      assert {:ok,
              %HostSpec{
                strict_host_key_checking: :yes,
                known_hosts: "/etc/ssh/known_hosts"
              }} =
               HostSpec.normalize(%{
                 host: "h",
                 strict_host_key_checking: "yes",
                 known_hosts: "/etc/ssh/known_hosts"
               })
    end

    # `workspace_root` is read by two modules that each build their own model of
    # it, and they only agree on a root that is rooted at `/` or at a tilde
    # prefix the transport will actually expand. `PathSafety` reads any
    # `~`-leading root as home-anchored and measures containment there;
    # `Ssh.quote_path/1` expands only `~` and `~user`. A root the two read
    # differently is refused at config time rather than resolving to a
    # different directory per connection.
    test "accepts a workspace_root the path checker and the transport agree on" do
      for root <- ["/var/lib/symphony", "~/symphony", "~build/ws", "~", "~_svc/ws"] do
        assert {:ok, %HostSpec{workspace_root: ^root}} =
                 HostSpec.normalize(%{host: "h", workspace_root: root}),
               "expected #{root} to be accepted"
      end
    end

    test "refuses a bash tilde prefix that is not a home directory" do
      # `~-` is $OLDPWD, `~+` is $PWD, `~0` / `~-1` are directory-stack entries.
      # Each resolves to wherever the login shell happened to have been, which
      # is a different directory per connection and outside the root containment
      # was measured against.
      for root <- ["~-/ws", "~0/ws", "~-1/ws", "~+/ws", "~-", "~2"] do
        assert {:error, {:invalid_ssh_host, _}} =
                 HostSpec.normalize(%{host: "h", workspace_root: root}),
               "expected #{root} to be refused"
      end
    end

    test "refuses a relative workspace_root, which has no fixed meaning on the host" do
      for root <- ["symphony", "ws/issues", "./ws", "../ws"] do
        assert {:error, {:invalid_ssh_host, _}} =
                 HostSpec.normalize(%{host: "h", workspace_root: root}),
               "expected #{root} to be refused"
      end
    end

    test "an absent workspace_root is still fine -- it falls back to the configured root" do
      assert {:ok, %HostSpec{workspace_root: nil}} = HostSpec.normalize(%{host: "h"})
    end

    # The other path fields are handed to `ssh` as argv, never to a shell, so
    # they keep the looser rule. Narrowing them would reject an ordinary
    # relative `-i` path for no gain.
    test "the tightening applies to workspace_root only" do
      assert {:ok, _} = HostSpec.normalize(%{host: "h", identity_file: "keys/id_ci"})
    end

    test "rejects an unknown mode from map input and a directly-built struct" do
      assert {:error, {:invalid_ssh_host, _}} =
               HostSpec.normalize(%{host: "h", strict_host_key_checking: "maybe"})

      assert {:error, {:invalid_ssh_host, _}} =
               HostSpec.normalize(%HostSpec{host: "h", strict_host_key_checking: :bogus})
    end

    test "host-key fields are not part of id/1" do
      base = HostSpec.id(%HostSpec{host: "h", user: "u", port: 22})

      hardened =
        HostSpec.id(%HostSpec{
          host: "h",
          user: "u",
          port: 22,
          strict_host_key_checking: :yes,
          known_hosts: "/etc/ssh/known_hosts"
        })

      assert base == hardened
    end
  end

  describe "id/1" do
    test "is user@host:port with absent parts omitted" do
      assert HostSpec.id(%HostSpec{host: "h"}) == "h"
      assert HostSpec.id(%HostSpec{host: "h", user: "u"}) == "u@h"
      assert HostSpec.id(%HostSpec{host: "h", user: "u", port: 22}) == "u@h:22"
    end

    test "the string and map forms of the same target share an id" do
      {:ok, from_string} = HostSpec.normalize("ci@build-1")
      {:ok, from_map} = HostSpec.normalize(%{host: "build-1", user: "ci"})
      assert HostSpec.id(from_string) == HostSpec.id(from_map)
    end
  end
end
