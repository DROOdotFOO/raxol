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
      assert {:ok,
              %HostSpec{host: "h", user: nil, port: nil, identity_file: nil}} =
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
