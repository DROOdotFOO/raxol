defmodule Mix.Tasks.Acp.Schema.Verify do
  @shortdoc "Verify the pinned ACP schema oracle files haven't drifted"

  @moduledoc """
  Recomputes the SHA256 of the vendored ACP (Agent Client Protocol) schema
  oracle files under `priv/schema-oracle/v1/` and compares them against the
  hashes recorded at pin time (see `priv/schema-oracle/PINNED.md`).

      mix acp.schema.verify

  These files are a dev/test-only oracle (Apache-2.0, upstream
  https://github.com/agentclientprotocol/agent-client-protocol, tag
  `schema-v1.19.0`). They are excluded from the published Hex package via
  `mix.exs` `:files` and exist purely so tests can validate our
  hand-written/generated ACP types against the protocol's own JSON Schema.

  Exits with a non-zero status (via `Mix.raise/1`) if either file is missing
  or its hash no longer matches the pinned value -- which means either the
  file was edited locally (don't -- re-run the pin procedure in
  `priv/schema-oracle/PINNED.md` instead) or corrupted.
  """

  use Mix.Task

  # Pinned at: schema-v1.19.0 (stable, published 2026-07-06T12:35:36Z,
  # commit e4dcf39453b5a092082e0f662d2be94ac89a4504). See PINNED.md for the
  # bump procedure and download URLs.
  @pinned %{
    "schema.json" => "92c1dfcda10dd47e99127500a3763da2b471f9ac61e12b9bf0430c32cf953796",
    "meta.json" => "e0bf36f8123b2544b499174197fdc371ec49a1b4572a35114513d56492741599"
  }

  @schema_dir Path.expand("../../../priv/schema-oracle/v1", __DIR__)

  @impl Mix.Task
  def run(_argv) do
    results = Enum.map(@pinned, &verify_one/1)

    failures = Enum.filter(results, &match?({:error, _, _}, &1))

    Enum.each(results, fn
      {:ok, filename, hash} ->
        Mix.shell().info("OK   #{filename}  #{hash}")

      {:error, filename, reason} ->
        Mix.shell().error("FAIL #{filename}  #{reason}")
    end)

    if failures != [] do
      Mix.raise(
        "ACP schema oracle drift detected (#{length(failures)}/#{map_size(@pinned)} file(s)). " <>
          "See #{Path.expand("../PINNED.md", @schema_dir)} for the pin/bump procedure."
      )
    else
      Mix.shell().info("ACP schema oracle matches pin (schema-v1.19.0).")
    end
  end

  defp verify_one({filename, expected_hash}) do
    path = Path.join(@schema_dir, filename)

    case File.read(path) do
      {:ok, contents} ->
        actual_hash = sha256_hex(contents)

        if actual_hash == expected_hash do
          {:ok, filename, actual_hash}
        else
          {:error, filename,
           "sha256 mismatch: expected #{expected_hash}, got #{actual_hash} (#{path})"}
        end

      {:error, reason} ->
        {:error, filename, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp sha256_hex(contents) do
    :crypto.hash(:sha256, contents)
    |> Base.encode16(case: :lower)
  end
end
