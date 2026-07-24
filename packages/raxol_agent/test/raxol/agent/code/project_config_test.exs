defmodule Raxol.Agent.Code.ProjectConfigTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Code.ProjectConfig

  defp project_with(config_json) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol-projcfg-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(dir, ".raxol"))

    if config_json,
      do: File.write!(Path.join(dir, ".raxol/config.json"), config_json)

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "loads a pinned provider, model, and base_url" do
    dir =
      project_with(~s({
        "provider": "anthropic",
        "model": "claude-sonnet-5",
        "base_url": "https://api.anthropic.com"
      }))

    assert ProjectConfig.load(dir) == %{
             provider: :anthropic,
             model: "claude-sonnet-5",
             base_url: "https://api.anthropic.com"
           }
  end

  test "a missing file is an empty config" do
    dir = project_with(nil)
    assert ProjectConfig.load(dir) == %{}
  end

  test "malformed JSON is an empty config, never a crash" do
    dir = project_with("{not json")
    assert ProjectConfig.load(dir) == %{}
  end

  test "a non-object body is an empty config" do
    dir = project_with(~s(["anthropic"]))
    assert ProjectConfig.load(dir) == %{}
  end

  test "an unknown provider name is dropped" do
    dir = project_with(~s({"provider": "not-a-provider", "model": "x"}))
    assert ProjectConfig.load(dir) == %{model: "x"}
  end

  test "a raw key field is ignored (references only, never secrets)" do
    dir =
      project_with(~s({
        "provider": "openai",
        "api_key": "sk-should-be-ignored",
        "key": "also-ignored"
      }))

    config = ProjectConfig.load(dir)
    assert config == %{provider: :openai}
    refute Map.has_key?(config, :api_key)
    refute Map.has_key?(config, :key)
  end

  test "blank / non-string fields are dropped" do
    dir = project_with(~s({"provider": "openai", "model": "", "base_url": 42}))
    assert ProjectConfig.load(dir) == %{provider: :openai}
  end
end
