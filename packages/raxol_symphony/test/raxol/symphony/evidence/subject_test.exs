defmodule Raxol.Symphony.Evidence.SubjectTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue}
  alias Raxol.Symphony.Evidence.Subject

  describe "from_workspace/2 with stub git_runner" do
    test "parses owner/name from a github SSH origin" do
      git = fn args, _cwd ->
        case args do
          ["config", "--get", "remote.origin.url"] -> {:ok, "git@github.com:raxol/test.git\n"}
          ["rev-parse", "--abbrev-ref", "HEAD"] -> {:ok, "main\n"}
        end
      end

      subject = Subject.from_workspace("/tmp/x", git_runner: git)
      assert subject.repo == "raxol/test"
      assert subject.ref == "main"
    end

    test "parses owner/name from a github HTTPS origin without .git suffix" do
      git = fn
        ["config", "--get", "remote.origin.url"], _ -> {:ok, "https://github.com/raxol/test\n"}
        ["rev-parse", "--abbrev-ref", "HEAD"], _ -> {:ok, "feature/x\n"}
      end

      subject = Subject.from_workspace("/tmp/x", git_runner: git)
      assert subject.repo == "raxol/test"
      assert subject.ref == "feature/x"
    end

    test "skips ref when HEAD is detached" do
      git = fn
        ["config", "--get", "remote.origin.url"], _ -> {:ok, "git@github.com:raxol/test.git\n"}
        ["rev-parse", "--abbrev-ref", "HEAD"], _ -> {:ok, "HEAD\n"}
      end

      subject = Subject.from_workspace("/tmp/x", git_runner: git)
      refute Map.has_key?(subject, :ref)
    end

    test "skips repo when origin is not GitHub" do
      git = fn
        ["config", "--get", "remote.origin.url"], _ -> {:ok, "git@gitlab.com:foo/bar.git\n"}
        ["rev-parse", "--abbrev-ref", "HEAD"], _ -> {:ok, "main\n"}
      end

      subject = Subject.from_workspace("/tmp/x", git_runner: git)
      refute Map.has_key?(subject, :repo)
      assert subject.ref == "main"
    end

    test "tolerates git failures silently" do
      git = fn _args, _cwd -> {:error, :anything} end
      subject = Subject.from_workspace("/tmp/x", git_runner: git)
      assert subject == %{workspace: "/tmp/x"}
    end
  end

  describe "from_workspace/2 with the default git" do
    @describetag :unix_only

    # The `git` on PATH reports its environment as the origin URL, so the
    # parsed repo name shows what a workspace's git would see.
    setup do
      dir = Path.join(System.tmp_dir!(), "subject-git-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      git = Path.join(dir, "git")

      File.write!(git, """
      #!/bin/sh
      printf 'git@github.com:env/%s.git\\n' "${RAXOL_SLEUTH_API_KEY-unset}"
      """)

      File.chmod!(git, 0o755)

      previous = %{
        "PATH" => System.get_env("PATH"),
        "RAXOL_SLEUTH_API_KEY" => System.get_env("RAXOL_SLEUTH_API_KEY")
      }

      System.put_env("PATH", dir <> ":" <> previous["PATH"])
      System.put_env("RAXOL_SLEUTH_API_KEY", "sk-probe-not-real")

      on_exit(fn ->
        Enum.each(previous, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)

        File.rm_rf!(dir)
      end)

      %{dir: dir}
    end

    test "git runs without raxol's secrets in its environment", %{dir: dir} do
      assert %{repo: "env/unset"} = Subject.from_workspace(dir)
    end
  end

  describe "augment/3" do
    test "lifts numeric identifier to issue_number when tracker is github" do
      cfg =
        Config.from_workflow(%{
          config: %{tracker: %{kind: "github", project_slug: "o/r"}},
          prompt_template: ""
        })

      assert %{issue_number: 42} =
               Subject.augment(%{workspace: "/tmp/x"}, cfg, %Issue{
                 id: "x",
                 identifier: "42",
                 title: "T",
                 state: "Todo"
               })
    end

    test "is a no-op for non-numeric identifiers" do
      cfg =
        Config.from_workflow(%{
          config: %{tracker: %{kind: "github"}},
          prompt_template: ""
        })

      subject =
        Subject.augment(%{workspace: "/tmp/x"}, cfg, %Issue{
          id: "x",
          identifier: "MT-1",
          title: "T",
          state: "Todo"
        })

      refute Map.has_key?(subject, :issue_number)
    end

    test "is a no-op when tracker is not github" do
      cfg =
        Config.from_workflow(%{
          config: %{tracker: %{kind: "linear"}},
          prompt_template: ""
        })

      subject =
        Subject.augment(%{workspace: "/tmp/x"}, cfg, %Issue{
          id: "x",
          identifier: "42",
          title: "T",
          state: "Todo"
        })

      refute Map.has_key?(subject, :issue_number)
    end
  end
end
