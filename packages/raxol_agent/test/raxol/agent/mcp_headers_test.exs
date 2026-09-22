defmodule Raxol.Agent.McpHeadersTest do
  # PATH, `$RAXOL_MCP_HEADER_ALLOWLIST` and the referenced env vars are all
  # process-wide.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Raxol.Agent.McpHeaders
  alias Raxol.Agent.OperatorFile

  @secret "op-resolved-s3cr3t"

  # A real `op` on PATH. It appends its argv to a log file, so "was `op`
  # spawned" is answered by the filesystem rather than by a flag this test
  # sets: if resolution happened, the file exists. The user-level test below
  # asserts it DOES exist, which is what calibrates the detector -- a shim that
  # was never reachable would make the negative assertion vacuous.
  defp shim(dir) do
    path = Path.join(dir, "op")
    log = Path.join(dir, "op.log")

    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$*" >> "#{log}"
    case "$*" in
      *fail*) printf '[ERROR] item not found: upstream-detail-text\\n'; exit 1 ;;
    esac
    printf '#{@secret}\\n'
    """)

    File.chmod!(path, 0o755)
    log
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "raxol-hdr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    log = shim(dir)

    previous_path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> (previous_path || ""))

    allowlist = Path.join(dir, "mcp_headers.json")
    previous_allowlist = System.get_env("RAXOL_MCP_HEADER_ALLOWLIST")
    System.put_env("RAXOL_MCP_HEADER_ALLOWLIST", allowlist)

    on_exit(fn ->
      restore("PATH", previous_path)
      restore("RAXOL_MCP_HEADER_ALLOWLIST", previous_allowlist)
      System.delete_env("INTEL_TOKEN")
      File.rm_rf!(dir)
    end)

    %{dir: dir, log: log, allowlist: allowlist}
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)

  defp allow(path, map), do: File.write!(path, Jason.encode!(map))

  describe "a workspace-sourced spec" do
    test "refuses an op:// reference with a named reason and spawns no op", %{log: log} do
      headers = [{"Authorization", "op://Employee/Intel/token"}]

      assert {:error, {:workspace_header_reference, "Authorization"}} =
               McpHeaders.resolve(headers, source: :workspace, server: :intel)

      refute File.exists?(log)
    end

    test "refuses an ${env:} reference with a named reason", %{log: log} do
      System.put_env("INTEL_TOKEN", "env-resolved-s3cr3t")
      headers = [{"Authorization", "Bearer ${env:INTEL_TOKEN}"}]

      assert {:error, {:workspace_header_reference, "Authorization"}} =
               McpHeaders.resolve(headers, source: :workspace, server: :intel)

      refute File.exists?(log)
    end

    test "the refusal names the header, never the reference or a value" do
      System.put_env("INTEL_TOKEN", "env-resolved-s3cr3t")

      {:error, reason} =
        McpHeaders.resolve([{"Authorization", "Bearer ${env:INTEL_TOKEN}"}],
          source: :workspace,
          server: :intel
        )

      refute inspect(reason) =~ "env-resolved-s3cr3t"
      refute inspect(reason) =~ "INTEL_TOKEN"
    end

    test "accepts a literal and warns once for the server, naming no value" do
      log =
        capture_log(fn ->
          assert {:ok, [{"Authorization", "Bearer sk-live-DEADBEEF"}, {"X-Account", "acct"}]} =
                   McpHeaders.resolve(
                     [{"Authorization", "Bearer sk-live-DEADBEEF"}, {"X-Account", "acct"}],
                     source: :workspace,
                     server: :intel
                   )
        end)

      assert log =~ "intel"
      assert log =~ "Authorization"
      refute log =~ "sk-live-DEADBEEF"
      # One line for the server, not one per header.
      assert length(String.split(log, "mcp headers:")) == 2
    end

    test "resolves only the reference the operator allowlisted for that header", %{
      allowlist: allowlist
    } do
      allow(allowlist, %{"authorization" => ["op://Employee/Intel/token"]})
      System.put_env("INTEL_TOKEN", "env-resolved-s3cr3t")

      assert {:ok, [{"Authorization", @secret}]} =
               McpHeaders.resolve([{"Authorization", "op://Employee/Intel/token"}],
                 source: :workspace,
                 server: :intel
               )

      assert {:error, {:workspace_header_reference, "Authorization"}} =
               McpHeaders.resolve([{"Authorization", "op://Employee/Other/token"}],
                 source: :workspace,
                 server: :intel
               )

      assert {:error, {:workspace_header_reference, "X-Key"}} =
               McpHeaders.resolve([{"X-Key", "op://Employee/Intel/token"}],
                 source: :workspace,
                 server: :intel
               )
    end

    test "an unreadable allowlist permits nothing", %{allowlist: allowlist} do
      File.write!(allowlist, "{not json")

      assert {:error, {:workspace_header_reference, "Authorization"}} =
               McpHeaders.resolve([{"Authorization", "op://Employee/Intel/token"}],
                 source: :workspace,
                 server: :intel
               )
    end
  end

  describe "a user-level spec" do
    test "resolves an op:// reference through op read", %{log: log} do
      assert {:ok, [{"Authorization", @secret}]} =
               McpHeaders.resolve([{"Authorization", "op://Employee/Intel/token"}],
                 source: :user,
                 server: :intel
               )

      # Calibrates the negative assertions above: the shim IS reachable, and
      # what reached it was the reference verbatim.
      assert File.read!(log) =~ "read op://Employee/Intel/token"
    end

    test "interpolates ${env:} and ${op://} inside a value" do
      System.put_env("INTEL_TOKEN", "env-resolved-s3cr3t")

      assert {:ok, [{"Authorization", "Bearer env-resolved-s3cr3t"}, {"X-Key", @secret}]} =
               McpHeaders.resolve(
                 [
                   {"Authorization", "Bearer ${env:INTEL_TOKEN}"},
                   {"X-Key", "${op://Employee/Intel/token}"}
                 ],
                 source: :user,
                 server: :intel
               )
    end

    test "a missing env var is a named failure carrying no value" do
      assert {:error, {:header_unresolved, "Authorization", :env_not_set}} =
               McpHeaders.resolve([{"Authorization", "Bearer ${env:INTEL_TOKEN}"}],
                 source: :user,
                 server: :intel
               )
    end

    test "an empty env var is refused rather than sent as an empty credential" do
      System.put_env("INTEL_TOKEN", "")

      assert {:error, {:header_unresolved, "Authorization", :env_empty}} =
               McpHeaders.resolve([{"Authorization", "${env:INTEL_TOKEN}"}],
                 source: :user,
                 server: :intel
               )
    end

    test "op's own failure text never reaches the error term or the log" do
      captured =
        capture_log(fn ->
          assert {:error, {:header_unresolved, "Authorization", {:op_read_failed, 1}}} =
                   McpHeaders.resolve([{"Authorization", "op://Employee/fail/token"}],
                     source: :user,
                     server: :intel
                   )
        end)

      refute captured =~ "upstream-detail-text"
    end
  end

  # The allowlist is the only thing standing between a cloned `.mcp.json` and
  # this operator's secrets, so where it comes from is part of the control.
  describe "an allowlist that is not demonstrably the operator's" do
    test "does not exist at all when the process has no home directory", %{dir: dir} do
      # What the old fallback would have read: `System.tmp_dir!/0` honours
      # TMPDIR, so this IS the `/tmp/.raxol/mcp_headers.json` any local user
      # could have created first.
      planted = Path.join([dir, ".raxol", "mcp_headers.json"])
      File.mkdir_p!(Path.dirname(planted))
      allow(planted, %{"Authorization" => ["${env:INTEL_TOKEN}"]})
      System.put_env("INTEL_TOKEN", "env-resolved-s3cr3t")

      previous_home = System.get_env("HOME")
      previous_tmp = System.get_env("TMPDIR")
      System.delete_env("RAXOL_MCP_HEADER_ALLOWLIST")
      System.put_env("TMPDIR", dir)
      System.delete_env("HOME")

      on_exit(fn ->
        restore("HOME", previous_home)
        restore("TMPDIR", previous_tmp)
      end)

      log =
        capture_log(fn ->
          assert {:error, {:workspace_header_reference, "Authorization"}} =
                   McpHeaders.resolve([{"Authorization", "${env:INTEL_TOKEN}"}],
                     source: :workspace,
                     server: :intel
                   )
        end)

      assert McpHeaders.allowlist_path() == nil
      assert log =~ "no home directory"
    end

    test "is refused when another account may write it", %{allowlist: allowlist} do
      allow(allowlist, %{"Authorization" => ["${env:INTEL_TOKEN}"]})
      File.chmod!(allowlist, 0o664)
      System.put_env("INTEL_TOKEN", "env-resolved-s3cr3t")

      log =
        capture_log(fn ->
          assert {:error, {:workspace_header_reference, "Authorization"}} =
                   McpHeaders.resolve([{"Authorization", "${env:INTEL_TOKEN}"}],
                     source: :workspace,
                     server: :intel
                   )
        end)

      assert log =~ "mode 0664"
      assert log =~ allowlist
    end

    # A test cannot chown, so the foreign owner is a file the system owns.
    # Running as root makes every file ours, and the premise unstageable.
    if OperatorFile.uid() not in [0, :unknown] do
      test "is refused, legibly, when another account owns it" do
        System.put_env("RAXOL_MCP_HEADER_ALLOWLIST", "/etc/hosts")
        System.put_env("INTEL_TOKEN", "env-resolved-s3cr3t")

        log =
          capture_log(fn ->
            assert {:error, {:workspace_header_reference, "Authorization"}} =
                     McpHeaders.resolve([{"Authorization", "${env:INTEL_TOKEN}"}],
                       source: :workspace,
                       server: :intel
                     )
          end)

        assert log =~ "owned by uid 0"
        assert log =~ "/etc/hosts"
      end
    end
  end
end
