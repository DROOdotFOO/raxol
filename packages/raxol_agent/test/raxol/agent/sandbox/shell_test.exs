defmodule Raxol.Agent.Sandbox.ShellTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Sandbox
  alias Raxol.Agent.Sandbox.Shell

  @ctx %{agent_id: :test, agent_module: nil}

  describe "constructors" do
    test "none/0 builds an abstain sandbox" do
      assert %Shell{mode: :none} = Shell.none()
    end

    test "deny_all/0 builds a wholesale-deny sandbox" do
      assert %Shell{mode: :deny_all} = Shell.deny_all()
    end

    test "allowlist/1 accepts a list of binaries" do
      assert %Shell{mode: {:allowlist, ["ls", "cat"]}} =
               Shell.allowlist(["ls", "cat"])
    end

    test "allowlist/1 accepts a 1-arity predicate" do
      pred = fn cmd -> String.starts_with?(cmd, "git ") end
      assert %Shell{mode: {:allowlist, ^pred}} = Shell.allowlist(pred)
    end

    test "denylist/1 accepts the same shapes" do
      assert %Shell{mode: {:denylist, ["rm"]}} = Shell.denylist(["rm"])
      pred = fn cmd -> String.contains?(cmd, "sudo") end
      assert %Shell{mode: {:denylist, ^pred}} = Shell.denylist(pred)
    end
  end

  # The command reaches `/bin/sh -c` as ONE string, so a first-token check only
  # decides anything for commands whose first token is what runs. Each of these
  # passed a first-token check while running something else entirely.
  describe "metacharacters defeat a first-token check, so list modes refuse them" do
    @wrappers [
      {"a separator", "cat x; cat /etc/shadow"},
      {"a background separator", "cat x & cat /etc/shadow"},
      {"an and-chain", "cat x && cat /etc/shadow"},
      {"an or-chain", "cat x || cat /etc/shadow"},
      {"a pipe", "cat x | sh"},
      {"a newline", "cat x\ncat /etc/shadow"},
      {"a carriage return", "cat x\rcat /etc/shadow"},
      {"command substitution", "cat $(cat /etc/shadow)"},
      {"backticks", "cat `cat /etc/shadow`"},
      {"a variable expansion", "cat $SECRET"},
      {"an output redirect", "cat x > /etc/cron.d/pwn"},
      {"an input redirect", "cat < /etc/shadow"},
      {"a nested sh -c", "cat x; sh -c 'cat /etc/shadow'"},
      {"an env assignment prefix", "LD_PRELOAD=/tmp/e.so cat x"},
      {"an escape", "cat x\\;cat /etc/shadow"},
      # `!` is POSIX pipeline negation: `sh -c '! cat x'` runs `cat` and
      # inverts its status. The first token is `!`, so a denylist naming the
      # binary never saw it -- the same shape as the assignment prefix above.
      {"pipeline negation", "! cat /etc/shadow"}
    ]

    for {label, command} <- @wrappers do
      test "an allowlist refuses #{label}" do
        refute Shell.allowed?(Shell.allowlist(["cat"]), unquote(command))
      end

      test "a denylist refuses #{label}" do
        # A denylist that does not name `cat` would otherwise wave this through
        # on the strength of a first token that is not what runs.
        refute Shell.allowed?(Shell.denylist(["rm"]), unquote(command))
      end
    end

    test "the plain forms those wrappers hide are still allowed" do
      assert Shell.allowed?(Shell.allowlist(["cat"]), "cat x")
      assert Shell.allowed?(Shell.allowlist(["cat"]), "cat -n a/b.txt")
      assert Shell.allowed?(Shell.denylist(["rm"]), "cat x")
    end

    test "a predicate still sees the whole string and decides for itself" do
      # Predicates were always the only shape that could express a real policy,
      # and they are unchanged: they get the command, metacharacters included.
      pred = Shell.allowlist(fn cmd -> String.starts_with?(cmd, "git ") end)
      assert Shell.allowed?(pred, "git log | head")
      refute Shell.allowed?(pred, "sh -c 'git log'")
    end

    test "absolute and relative paths do not smuggle a denied binary" do
      # `binary_name/1` compares the literal token, so `/bin/rm` is not `rm`.
      # A denylist is a convenience, not a boundary; say so in a test rather
      # than leaving the reader to assume it holds.
      assert Shell.allowed?(Shell.denylist(["rm"]), "/bin/rm -rf /")
      refute Shell.allowed?(Shell.allowlist(["rm"]), "/bin/rm -rf /")
    end
  end

  describe "allowed?/2" do
    test "none abstains -> allow" do
      assert Shell.allowed?(Shell.none(), "anything")
    end

    test "deny_all -> reject" do
      refute Shell.allowed?(Shell.deny_all(), "ls")
    end

    test "allowlist by binary name allows listed commands with args" do
      sandbox = Shell.allowlist(["ls", "cat"])
      assert Shell.allowed?(sandbox, "ls")
      assert Shell.allowed?(sandbox, "ls -la /tmp")
      assert Shell.allowed?(sandbox, "cat /etc/passwd")
      refute Shell.allowed?(sandbox, "rm -rf /")
    end

    test "allowlist by predicate" do
      sandbox = Shell.allowlist(fn cmd -> String.starts_with?(cmd, "git ") end)
      assert Shell.allowed?(sandbox, "git status")
      refute Shell.allowed?(sandbox, "ls")
    end

    test "denylist rejects listed commands but allows others" do
      sandbox = Shell.denylist(["rm", "dd"])
      refute Shell.allowed?(sandbox, "rm -rf /")
      refute Shell.allowed?(sandbox, "dd if=/dev/zero")
      assert Shell.allowed?(sandbox, "ls")
    end

    test "denylist by predicate" do
      sandbox = Shell.denylist(fn cmd -> String.contains?(cmd, "sudo") end)
      refute Shell.allowed?(sandbox, "sudo apt update")
      assert Shell.allowed?(sandbox, "apt list")
    end
  end

  describe "authorize/4 (protocol)" do
    test "abstains for non-shell actions" do
      assert :ok =
               Sandbox.authorize(
                 Shell.deny_all(),
                 :async,
                 %{fun: fn _ -> :ok end},
                 @ctx
               )

      assert :ok =
               Sandbox.authorize(
                 Shell.deny_all(),
                 :send_agent,
                 %{target_id: :x, message: :hi},
                 @ctx
               )
    end

    test "allows when command is permitted" do
      sandbox = Shell.allowlist(["ls"])

      assert :ok =
               Sandbox.authorize(sandbox, :shell, %{command: "ls -la"}, @ctx)
    end

    test "denies with :shell_denied + mode + command on rejection" do
      sandbox = Shell.allowlist(["ls"])

      assert {:deny, {:shell_denied, {:allowlist, ["ls"]}, "rm -rf"}} =
               Sandbox.authorize(sandbox, :shell, %{command: "rm -rf"}, @ctx)
    end

    test "denies on malformed payload" do
      assert {:deny, {:shell_malformed_payload, _}} =
               Sandbox.authorize(Shell.none(), :shell, %{not_command: :x}, @ctx)
    end
  end
end
