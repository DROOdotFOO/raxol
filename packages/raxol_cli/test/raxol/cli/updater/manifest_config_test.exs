defmodule Raxol.CLI.Updater.ManifestConfigTest do
  # Application env is global.
  use ExUnit.Case, async: false

  alias Raxol.CLI.Updater.Manifest

  setup do
    saved =
      for app <- [:raxol_cli, :raxol], do: {app, Application.fetch_env(app, :updater_manifest)}

    on_exit(fn -> Enum.each(saved, &restore/1) end)
  end

  defp restore({app, {:ok, value}}), do: Application.put_env(app, :updater_manifest, value)
  defp restore({app, :error}), do: Application.delete_env(app, :updater_manifest)

  test "load/1 reads the channel from the :raxol_cli application" do
    Application.put_env(:raxol_cli, :updater_manifest, repo: "acme/widget", tag_prefix: "v")

    assert {:ok, %Manifest{repo: "acme/widget", tag_prefix: "v"}} = Manifest.load()
  end

  test "load/1 does not read the key from the :raxol application" do
    Application.delete_env(:raxol_cli, :updater_manifest)
    Application.put_env(:raxol, :updater_manifest, repo: "acme/widget")

    assert {:ok, %Manifest{repo: "DROOdotFOO/raxol"}} = Manifest.load()
  end
end
