# CI guard: a journal `schema_version` bump must leave a frozen golden corpus
# behind, and a frozen corpus is immutable.
#
#   elixir scripts/check_journal_goldens.exs           # check (CI)
#   elixir scripts/check_journal_goldens.exs --bless   # rewrite the manifest
#
# Why this exists. `Raxol.Agent.Journal.FileStore.Writer` stamps every record
# with a `schema_version`. The upcast-on-read chain that lets a future reader
# open an old journal is designed but unwritten -- and it can only ever be
# TESTED against real journals written by the versions it claims to upcast.
# Those are unrecoverable once the writer moves on: nothing regenerates a
# 1.0.0 journal after the default is 1.2.0. So each version gets exactly one
# frozen corpus, at the moment it is current, and never loses it.
#
# The rule, enforced below:
#
#   1. the CURRENT default has a frozen fixture -- so a bump to 1.2.0 fails
#      until 1.2.0 is frozen, which by construction is also the moment 1.1.0
#      (the prior version) is already frozen and pinned here;
#   2. every fixture the manifest names still exists, with the exact same file
#      set and the exact same bytes -- history is not editable in place;
#   3. every fixture on disk is named by the manifest -- an unblessed addition
#      is a review event, not a silent one.
#
# Deliberately dependency-free (OTP `:json`, no Mix project load): it has to
# run in the per-PR `format` job, where `raxol_agent` -- which is a local gate,
# not a per-PR CI package -- is never compiled.

repo_root = Path.expand("..", __DIR__)
package = Path.join(repo_root, "packages/raxol_agent")
writer_path = Path.join(package, "lib/raxol/agent/journal/file_store/writer.ex")
goldens_dir = Path.join(package, "test/invariants/fixtures/golden")
manifest_path = Path.join(goldens_dir, "MANIFEST.json")
freezer = "packages/raxol_agent/scripts/freeze_golden_journal.exs"

bless? = "--bless" in System.argv()

die = fn message ->
  IO.puts(:stderr, "journal goldens: #{message}")
  System.halt(1)
end

# --- the writer's current default -------------------------------------------

writer_source =
  case File.read(writer_path) do
    {:ok, source} ->
      source

    {:error, reason} ->
      die.("cannot read #{writer_path}: #{:file.format_error(reason)}")
  end

default_version =
  case Regex.run(~r/@default_schema_version\s+"([^"]+)"/, writer_source) do
    [_, version] ->
      version

    nil ->
      die.(
        "no @default_schema_version found in #{Path.relative_to(writer_path, repo_root)}"
      )
  end

# --- what is on disk ---------------------------------------------------------

fixture_files = fn dir ->
  dir
  |> Path.join("**/*")
  |> Path.wildcard()
  |> Enum.reject(&File.dir?/1)
  |> Enum.map(&Path.relative_to(&1, dir))
  |> Enum.sort()
end

digest = fn path ->
  path
  |> File.read!()
  |> then(&:crypto.hash(:sha256, &1))
  |> Base.encode16(case: :lower)
end

# `golden/v<version>/<session>/...` -- one session dir per frozen version.
on_disk =
  goldens_dir
  |> Path.join("v*")
  |> Path.wildcard()
  |> Enum.filter(&File.dir?/1)
  |> Map.new(fn version_dir ->
    "v" <> version = Path.basename(version_dir)

    session =
      case version_dir
           |> Path.join("*")
           |> Path.wildcard()
           |> Enum.filter(&File.dir?/1) do
        [session_dir] ->
          Path.basename(session_dir)

        other ->
          die.(
            "golden/v#{version} must hold exactly one session directory, found #{length(other)}"
          )
      end

    session_dir = Path.join(version_dir, session)

    files =
      session_dir
      |> fixture_files.()
      |> Map.new(&{&1, digest.(Path.join(session_dir, &1))})

    {version, %{"session" => session, "files" => files}}
  end)

# --- bless: rewrite the manifest from disk ----------------------------------

if bless? do
  entry_json = fn {version, %{"session" => session, "files" => files}} ->
    files_json =
      files
      |> Enum.sort()
      |> Enum.map_join(",\n", fn {name, sha} ->
        ~s(        "#{name}": "#{sha}")
      end)

    """
        "#{version}": {
          "session": "#{session}",
          "files": {
    #{files_json}
          }
        }\
    """
  end

  versions_json = on_disk |> Enum.sort() |> Enum.map_join(",\n", entry_json)

  File.write!(manifest_path, """
  {
    "_comment": [
      "Frozen golden journal corpora, one per schema_version. Pinned by",
      "scripts/check_journal_goldens.exs: a schema_version bump without a new",
      "frozen fixture fails CI, and these bytes are immutable history.",
      "Freeze a new version with #{freezer}, then re-bless."
    ],
    "current_schema_version": "#{default_version}",
    "versions": {
  #{versions_json}
    }
  }
  """)

  IO.puts(
    "blessed #{map_size(on_disk)} frozen corpora (current #{default_version}) -> " <>
      Path.relative_to(manifest_path, repo_root)
  )

  System.halt(0)
end

# --- check -------------------------------------------------------------------

manifest =
  case File.read(manifest_path) do
    {:ok, body} ->
      :json.decode(body)

    {:error, reason} ->
      die.("cannot read the manifest: #{:file.format_error(reason)}")
  end

pinned = Map.fetch!(manifest, "versions")

problems =
  []
  |> then(fn problems ->
    # Rule 1 -- the bump gate. A version bump lands with the fixture for the
    # version it is leaving behind already pinned (that fixture was frozen when
    # IT was current), and cannot land until the new one is frozen too.
    if manifest["current_schema_version"] == default_version do
      problems
    else
      [
        "the writer default is #{default_version} but the manifest pins " <>
          "#{inspect(manifest["current_schema_version"])} as current.\n" <>
          "  A schema_version bump must freeze a corpus for the new version:\n" <>
          "    cd packages/raxol_agent && MIX_ENV=test mix run scripts/freeze_golden_journal.exs\n" <>
          "    elixir scripts/check_journal_goldens.exs --bless\n" <>
          "  The frozen corpus for every PRIOR version stays exactly as it is —\n" <>
          "  it is the only test material a future upcast-on-read will ever have."
        | problems
      ]
    end
  end)
  |> then(fn problems ->
    if Map.has_key?(pinned, default_version) do
      problems
    else
      [
        "no frozen corpus for the current schema_version #{default_version}"
        | problems
      ]
    end
  end)
  |> then(fn problems ->
    # Rule 3 -- nothing unblessed on disk.
    case Map.keys(on_disk) -- Map.keys(pinned) do
      [] ->
        problems

      extra ->
        [
          "golden corpora on disk but absent from the manifest: #{Enum.join(extra, ", ")}"
          | problems
        ]
    end
  end)

# Rule 2 -- every pinned corpus still exists, byte for byte.
problems =
  Enum.reduce(Enum.sort(pinned), problems, fn {version, spec}, problems ->
    case Map.fetch(on_disk, version) do
      :error ->
        [
          "frozen corpus for #{version} is GONE from disk — history is not deletable"
          | problems
        ]

      {:ok, actual} ->
        expected_files = spec["files"]
        actual_files = actual["files"]

        problems =
          if actual["session"] == spec["session"] do
            problems
          else
            [
              "#{version}: session dir renamed #{spec["session"]} -> #{actual["session"]}"
              | problems
            ]
          end

        problems =
          case Map.keys(expected_files) -- Map.keys(actual_files) do
            [] ->
              problems

            missing ->
              [
                "#{version}: missing file(s) #{Enum.join(missing, ", ")}"
                | problems
              ]
          end

        problems =
          case Map.keys(actual_files) -- Map.keys(expected_files) do
            [] ->
              problems

            added ->
              [
                "#{version}: unpinned file(s) #{Enum.join(added, ", ")}"
                | problems
              ]
          end

        Enum.reduce(expected_files, problems, fn {name, sha}, problems ->
          case Map.fetch(actual_files, name) do
            {:ok, ^sha} ->
              problems

            {:ok, other} ->
              [
                "#{version}: #{name} was EDITED (pinned #{String.slice(sha, 0, 12)}…, " <>
                  "found #{String.slice(other, 0, 12)}…) — a frozen corpus is history, " <>
                  "not a fixture to update"
                | problems
              ]

            :error ->
              problems
          end
        end)
    end
  end)

case Enum.reverse(problems) do
  [] ->
    IO.puts(
      "journal goldens OK — #{map_size(pinned)} frozen corpora pinned, " <>
        "current schema_version #{default_version}"
    )

  problems ->
    IO.puts(:stderr, "journal golden fixture guard FAILED:\n")
    Enum.each(problems, &IO.puts(:stderr, "  - #{&1}\n"))
    System.halt(1)
end
