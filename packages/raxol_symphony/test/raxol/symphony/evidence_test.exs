defmodule Raxol.Symphony.EvidenceTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.{Config, Evidence}

  defmodule HappyBackend do
    @behaviour Raxol.Symphony.Evidence.Backend
    @impl true
    def collect(evidence, _config, opts) do
      key = Keyword.fetch!(opts, :key)
      %{evidence | ci: Map.put(evidence.ci || %{}, key, :ok)}
    end
  end

  defmodule FailingBackend do
    @behaviour Raxol.Symphony.Evidence.Backend
    @impl true
    def collect(_evidence, _config, _opts), do: raise("kaboom")
  end

  defmodule ErroringBackend do
    @behaviour Raxol.Symphony.Evidence.Backend
    @impl true
    def collect(evidence, _config, _opts),
      do: Evidence.put_error(evidence, :erroring, :synthetic)
  end

  defp config do
    Config.from_workflow(%{
      config: %{tracker: %{kind: "memory"}},
      prompt_template: ""
    })
  end

  describe "collect/3" do
    test "fans out to backends and accumulates state" do
      evidence =
        Evidence.collect(config(), %{workspace: "/tmp/x"},
          backends: [
            {HappyBackend, key: :a},
            {HappyBackend, key: :b}
          ]
        )

      assert evidence.workspace == "/tmp/x"
      assert evidence.ci == %{a: :ok, b: :ok}
      assert evidence.errors == %{}
    end

    test "subject fields land on the struct" do
      subject = %{workspace: "/tmp/x", repo: "o/r", ref: "main", issue_number: 7}
      evidence = Evidence.collect(config(), subject, backends: [])

      assert %Evidence{repo: "o/r", ref: "main", issue_number: 7} = evidence
    end

    test "explicit put_error from a backend lands in :errors" do
      evidence =
        Evidence.collect(config(), %{workspace: "/tmp/x"}, backends: [{ErroringBackend, []}])

      assert evidence.errors == %{erroring: :synthetic}
    end

    test "raised exceptions are caught and tagged in :errors" do
      evidence =
        Evidence.collect(config(), %{workspace: "/tmp/x"},
          backends: [{FailingBackend, []}, {HappyBackend, key: :ok}]
        )

      assert {:exception, %RuntimeError{message: "kaboom"}} = evidence.errors[:failing_backend]
      assert evidence.ci == %{ok: :ok}
    end
  end

  describe "to_map/1" do
    test "produces a JSON-friendly map with stringified errors" do
      evidence = %Evidence{
        workspace: "/tmp/x",
        ci: %{status: "ok"},
        errors: %{github: :no_token}
      }

      assert %{
               workspace: "/tmp/x",
               ci: %{status: "ok"},
               errors: %{github: ":no_token"}
             } = Evidence.to_map(evidence)
    end
  end
end
