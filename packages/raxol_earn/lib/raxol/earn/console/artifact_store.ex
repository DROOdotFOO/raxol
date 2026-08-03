defmodule Raxol.Earn.Console.ArtifactStore do
  @moduledoc """
  Storage seam for delivery artifacts (the package tarball, the evidence
  transcript, the validation report). The deliverable carries URLs, so the
  store's only contract is: bytes in, stable URL out — at a
  **`job_id`-deterministic path**, which is what makes a replayed
  `handle_deliver/2` re-find the same artifact instead of minting a second one
  (DESIGN.md §5.3).

      config :raxol_earn, :console_artifact_store,
        module: Raxol.Earn.Console.ArtifactStore.Local,
        dir: "/var/lib/raxol/console_artifacts",
        base_url: "https://artifacts.example.com/console"

  `Local` writes `dir/<job_id>/<filename>` and returns
  `base_url/<job_id>/<filename>` (or a `file://` URL when `base_url` is unset —
  fine for tests and bench runs, not for a live offering). An S3/R2 impl slots
  in behind the same behaviour without touching delivery.
  """

  @callback put(job_id :: binary(), filename :: String.t(), bytes :: binary()) ::
              {:ok, url :: String.t()} | {:error, term()}

  @doc "Store through the configured module."
  @spec put(binary(), String.t(), binary()) :: {:ok, String.t()} | {:error, term()}
  def put(job_id, filename, bytes) do
    cfg = Application.get_env(:raxol_earn, :console_artifact_store, [])
    module = Keyword.get(cfg, :module, __MODULE__.Local)
    module.put(job_id, filename, bytes)
  end

  defmodule Local do
    @moduledoc false
    @behaviour Raxol.Earn.Console.ArtifactStore

    @impl true
    def put(job_id, filename, bytes) do
      cfg = Application.get_env(:raxol_earn, :console_artifact_store, [])

      with {:ok, dir} <- fetch_dir(cfg),
           safe_job = sanitize(job_id),
           target_dir = Path.join(dir, safe_job),
           :ok <- File.mkdir_p(target_dir),
           path = Path.join(target_dir, filename),
           :ok <- File.write(path, bytes) do
        case Keyword.get(cfg, :base_url) do
          nil -> {:ok, "file://" <> path}
          base -> {:ok, Enum.join([String.trim_trailing(base, "/"), safe_job, filename], "/")}
        end
      else
        {:error, reason} -> {:error, {:artifact_store, reason}}
      end
    end

    defp fetch_dir(cfg) do
      case Keyword.get(cfg, :dir) do
        nil -> {:error, :no_dir_configured}
        dir -> {:ok, dir}
      end
    end

    defp sanitize(job_id), do: String.replace(to_string(job_id), ~r/[^A-Za-z0-9_.-]/, "_")
  end
end
