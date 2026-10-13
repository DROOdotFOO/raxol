defmodule Raxol.Mix.SiblingDepsTest do
  @moduledoc """
  Every project Dependabot resolves (`.github/dependabot.yml`: `/` and
  `/packages/*`) declares its siblings through a `raxol_dep`-style helper that
  hands out a path dep in this checkout and a Hex requirement in a publish and
  in a consumer's `deps/`. Dependabot is a third reader of these files: it
  copies a project's mix.exs and mix.lock into an otherwise empty sandbox and
  runs `mix deps.get` there, so the sibling directories are absent, and a
  helper that takes absence for a Hex install locks the siblings as Hex
  packages. `scripts/check_lock_path_shadows.exs` rejects exactly those
  entries, so such a lock fails CI on every bump (#1220, #1247, #1248, #1249,
  #1252).

  These tests evaluate each project's deps from the sandbox Dependabot would
  build for it, and from the same sandbox marked as a Hex install.
  """

  # Each evaluation runs with the VM's working directory moved into a scratch
  # sandbox, and loading a package project goes through Mix.Project.in_project/4,
  # which does the same. Both are process-global.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  @root Path.expand("../..", __DIR__)

  # Dependabot writes a project to the directory it has in the repo, so a
  # package's `../..` resolves to the sandbox root exactly as it does to the
  # repo root.
  @project_dirs ["."] ++
                  (@root
                   |> Path.join("packages/*/mix.exs")
                   |> Path.wildcard()
                   |> Enum.map(&Path.relative_to(Path.dirname(&1), @root))
                   |> Enum.sort())

  setup_all do
    hex_build = System.get_env("HEX_BUILD")
    System.delete_env("HEX_BUILD")
    on_exit(fn -> if hex_build, do: System.put_env("HEX_BUILD", hex_build) end)
    :ok
  end

  test "a sandbox holding only mix.exs and mix.lock keeps every sibling a path dep",
       %{tmp_dir: tmp_dir} do
    for dir <- @project_dirs do
      sandbox = write_sandbox(tmp_dir, dir)
      config = project_config(dir, sandbox)
      hex_siblings = config |> sibling_deps() |> Enum.reject(&path_dep?/1)

      assert hex_siblings == [],
             "#{dir}/mix.exs resolves siblings from Hex when their directories " <>
               "are absent: #{inspect(Enum.map(hex_siblings, &elem(&1, 0)))}"
    end
  end

  # Only a project with a `package` config can be installed from Hex;
  # raxol_web3 has none and declares its siblings as plain path deps.
  test "a Hex install takes every sibling from Hex", %{tmp_dir: tmp_dir} do
    for dir <- @project_dirs do
      sandbox = write_sandbox(tmp_dir, dir)
      File.write!(Path.join(sandbox, "hex_metadata.config"), "")
      config = project_config(dir, sandbox)
      path_siblings = config |> sibling_deps() |> Enum.filter(&path_dep?/1)

      assert config[:package] == nil or path_siblings == [],
             "#{dir}/mix.exs keeps path deps inside a Hex install: " <>
               inspect(Enum.map(path_siblings, &elem(&1, 0)))
    end
  end

  defp write_sandbox(tmp_dir, dir) do
    sandbox = Path.join(tmp_dir, dir)
    File.mkdir_p!(sandbox)

    for file <- ["mix.exs", "mix.lock"],
        source = Path.join([@root, dir, file]),
        File.regular?(source) do
      File.cp!(source, Path.join(sandbox, file))
    end

    sandbox
  end

  defp project_config(dir, sandbox) do
    module = project_module(dir)
    File.cd!(sandbox, fn -> module.project() end)
  end

  defp sibling_deps(config) do
    config[:deps]
    |> List.flatten()
    |> Enum.map(&normalize_dep/1)
    |> Enum.filter(fn {name, _opts} ->
      String.starts_with?(Atom.to_string(name), "raxol")
    end)
  end

  defp project_module("."), do: Mix.Project.get()

  defp project_module(dir) do
    app = dir |> Path.basename() |> String.to_atom()

    Mix.Project.in_project(app, Path.join(@root, dir), [], fn module ->
      module
    end)
  end

  defp normalize_dep({name, opts}) when is_list(opts), do: {name, opts}
  defp normalize_dep({name, _requirement}), do: {name, []}
  defp normalize_dep({name, _requirement, opts}), do: {name, opts}

  defp path_dep?({_name, opts}), do: Keyword.has_key?(opts, :path)
end
