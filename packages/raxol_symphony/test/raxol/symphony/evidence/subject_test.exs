defmodule Raxol.Symphony.Evidence.SubjectTest do
  use ExUnit.Case, async: true

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
