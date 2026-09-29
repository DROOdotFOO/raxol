# CI guard: a mix.lock must not lock, as a Hex package, a dependency that its
# project resolves from a path (or git).
#
#   mix run --no-start --no-compile --no-deps-check scripts/check_lock_path_shadows.exs        # check (CI)
#   mix run --no-start --no-compile --no-deps-check scripts/check_lock_path_shadows.exs --fix  # drop them
#
# Run it from the project whose lock it checks: the repo root, web/, or
# packages/<name>/ (as ../../scripts/check_lock_path_shadows.exs). Needs no
# fetched deps and compiles nothing.
#
# Why this exists. On every `mix deps.get`, Hex takes each dependency that is
# NOT a Hex package out of the lock by name, and then also unlocks every package
# the old lock entry under that name lists as a child, recursively, optional
# children included (`Hex.RemoteConverger.prepare_locked/3` and
# `with_children/2`, Hex 2.5.1). A path dependency normally has no lock entry, so
# that walk is empty. A leftover `"raxol_liveview": {:hex, ...}` entry beside a
# `path:` raxol_liveview makes it walk phoenix_live_view -> igniter -> req ->
# finch -> mint, and everything on the way is resolved afresh on every run.
# `--check-locked` stays green until one of those packages publishes, then
# fails the same day ("Upgraded: finch 0.23.0 => 0.24.0 ... Your mix.lock is
# out of date") although every constraint still accepts the locked version.
# That is what #1048, #1060, #1071, #1089, #1146 and #1163 each refreshed a
# lock for, always in the same three lockfiles.
#
# How the entries get in: resolving in Hex mode. `HEX_BUILD=1`, or any checkout
# where a `raxol_dep` helper falls back to the Hex form because the sibling
# directory is absent, locks the siblings as Hex packages (the root's six were
# last rewritten by #1021, a Dependabot raxol_sensor bump). Path mode then never
# reads them and never removes them -- `mix deps.get` merges the old lock into
# the new one -- and `mix deps.unlock --check-unused` cannot see them, because
# the name is still a dependency.
#
# Uses Mix's internal converger, the one `mix deps.unlock --check-unused` runs,
# because only it sees every environment the way `mix deps.get` does.

# Resolved through the filesystem (macOS: /tmp is /private/tmp) so that it
# compares equal to File.cwd!/0 when paths are made relative below.
repo_root = File.cd!(Path.expand("..", __DIR__), &File.cwd!/0)
cwd = File.cwd!()
fix? = "--fix" in System.argv()

lock = Mix.Dep.Lock.read()

lockfile =
  Path.relative_to(Path.expand(Mix.Project.config()[:lockfile]), repo_root)

hex_entry? = fn entry -> is_tuple(entry) and elem(entry, 0) == :hex end

# Every environment and target, as `mix deps.get` without --only hands them to
# Hex.
shadows =
  for %Mix.Dep{app: app, scm: scm} <- Mix.Dep.Converger.converge([]),
      scm != Hex.SCM,
      hex_entry?.(lock[app]),
      uniq: true,
      do: app

shadows = Enum.sort(shadows)

listing =
  Enum.map_join(
    shadows,
    "\n",
    &"  * #{inspect(&1)} (locked as hex #{elem(lock[&1], 2)})"
  )

cond do
  shadows == [] ->
    IO.puts("#{lockfile}: no Hex entry shadows a path or git dependency")

  fix? ->
    Mix.Dep.Lock.write(Map.drop(lock, shadows))

    IO.puts(
      "#{lockfile}: removed Hex entries for path/git dependencies:\n\n#{listing}"
    )

  true ->
    script = Path.join(repo_root, "scripts/check_lock_path_shadows.exs")
    run = "mix run --no-start --no-compile --no-deps-check"
    run = "#{run} #{Path.relative_to(script, cwd, force: true)} --fix"

    command =
      case Path.relative_to(cwd, repo_root) do
        "." -> run
        project_dir -> "(cd #{project_dir} && #{run})"
      end

    IO.puts(:stderr, """
    #{lockfile} locks path/git dependencies as Hex packages:

    #{listing}

    On every `mix deps.get`, Hex unlocks each of these names together with every
    package its stale entry lists as a child, recursively, so none of those
    packages is pinned by the lock: the day any of them publishes a release,
    `mix deps.get --check-locked` fails. Path mode never uses these entries.
    Remove them (from the repo root) and commit the lock:

        #{command}
    """)

    System.halt(1)
end
