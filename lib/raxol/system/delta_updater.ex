defmodule Raxol.System.DeltaUpdater do
  @moduledoc """
  Binary-delta self-updates: fetch a small bsdiff patch instead of the full
  binary, and prove the result before it replaces anything.

  A delta asset is named `<delta_prefix>-<from>-<to>-<platform>.bin` (see
  `Raxol.System.Updater.Manifest.delta_asset/4`) and must be listed in the
  release's `SHA256SUMS`. The delta's own checksum is verified before the
  patch tool runs, and the patched output must hash to the *full* asset's
  published checksum before it is installed. The patched binary is never
  executed to check it. Deltas apply only to raw-binary channels (`format:
  :binary`), where the full asset's checksum is the executable's checksum.

  Options (all optional; each defaults to the running installation):

    * `:manifest` - see `Raxol.System.Updater.Manifest.load/1`
    * `:current_version`, `:current_executable`, `:platform`
    * `:backup_dir` - where the replaced executable is kept for rollback
    * `:work_dir` - scratch directory for the download and patch output
    * `:apply_patch` - `(old, delta, new -> :ok | {:error, term})`, default
      `bspatch old new delta`
  """

  alias Raxol.System.Updater.{Core, Manifest, Network}

  @type delta_info :: %{
          delta_size: non_neg_integer(),
          full_size: non_neg_integer(),
          savings_percent: integer(),
          delta_url: String.t(),
          full_url: String.t()
        }

  @doc """
  Whether a delta from the installed version to `target_version` is
  published and is less than half the size of the full binary.
  """
  @spec check_delta_availability(String.t(), keyword()) ::
          {:ok, delta_info()} | {:error, term()}
  def check_delta_availability(target_version, opts \\ []) do
    with {:ok, ctx} <- Core.resolve(target_version, opts),
         :ok <- binary_channel(ctx.manifest),
         {:ok, current} <- Core.current_version(ctx.manifest, opts),
         {:ok, names} <- asset_names(ctx, current),
         {:ok, sizes} <- asset_sizes(ctx.release, names) do
      delta_info(ctx, names, sizes)
    end
  end

  @doc """
  Updates the running executable to `target_version` by delta. Returns
  `{:error, :delta_not_found}` when the release carries no delta from the
  installed version, so a caller can fall back to a full update.
  """
  @spec apply_delta_update(String.t(), keyword()) :: :ok | {:error, term()}
  def apply_delta_update(target_version, opts \\ []) do
    with {:ok, ctx} <- Core.resolve(target_version, opts),
         {:ok, plan} <- Core.plan(ctx, opts) do
      plan =
        Map.put(plan, :apply_patch, Keyword.get(opts, :apply_patch, &bspatch/3))

      Core.with_work_dir(opts, &apply_delta(Map.put(plan, :work_dir, &1)))
    end
  end

  @doc false
  # The delta step of a full self-update, given an already-resolved release
  # and its checksums (so `Raxol.System.Updater.Core` does not refetch them).
  @spec apply_delta(map()) :: :ok | {:error, term()}
  def apply_delta(plan) do
    with :ok <- binary_channel(plan.manifest),
         {:ok, names} <- asset_names(plan, plan.from_version),
         {:ok, _size} <- asset_size(plan.release, names.delta, :delta_not_found),
         {:ok, shas} <- checksums(plan.checksums, names),
         {:ok, patched} <- fetch_and_patch(plan, names, shas) do
      Network.install_executable(
        plan.current_exe,
        patched,
        plan.backup_dir,
        plan.platform
      )
    end
  end

  # Downloads the delta, verifies it, patches, and verifies the output
  # against the full binary's checksum. Nothing is executed.
  defp fetch_and_patch(plan, names, shas) do
    delta_path = Path.join(plan.work_dir, names.delta)
    patched = Path.join(plan.work_dir, names.full)
    url = Manifest.asset_url(plan.manifest, plan.release.tag, names.delta)

    with :ok <- Network.download(url, delta_path),
         :ok <- Network.verify_file(delta_path, shas.delta, names.delta),
         :ok <- plan.apply_patch.(plan.current_exe, delta_path, patched),
         :ok <- Network.verify_file(patched, shas.full, names.full) do
      {:ok, patched}
    end
  end

  defp asset_names(
         %{manifest: manifest, platform: platform, release: release},
         from
       ) do
    with {:ok, full} <- Manifest.asset(manifest, platform) do
      {:ok,
       %{
         full: full,
         delta: Manifest.delta_asset(manifest, from, release.version, platform)
       }}
    end
  end

  defp checksums(sums, names) do
    with {:ok, delta} <- Network.checksum_for(sums, names.delta),
         {:ok, full} <- Network.checksum_for(sums, names.full) do
      {:ok, %{delta: delta, full: full}}
    end
  end

  defp asset_sizes(release, names) do
    with {:ok, full} <- asset_size(release, names.full, :full_package_not_found),
         {:ok, delta} <- asset_size(release, names.delta, :delta_not_found) do
      {:ok, %{full: full, delta: delta}}
    end
  end

  defp delta_info(ctx, names, %{full: full, delta: delta})
       when delta < full * 0.5 do
    {:ok,
     %{
       delta_size: delta,
       full_size: full,
       savings_percent: round((1 - delta / full) * 100),
       delta_url:
         Manifest.asset_url(ctx.manifest, ctx.release.tag, names.delta),
       full_url: Manifest.asset_url(ctx.manifest, ctx.release.tag, names.full)
     }}
  end

  defp delta_info(_ctx, _names, _sizes), do: {:error, :delta_too_large}

  defp binary_channel(%Manifest{format: :binary}), do: :ok

  defp binary_channel(%Manifest{format: format}),
    do: {:error, {:delta_unsupported, format}}

  defp asset_size(%{assets: assets}, name, missing) do
    case Map.fetch(assets, name) do
      {:ok, size} when is_integer(size) -> {:ok, size}
      {:ok, _size} -> {:ok, 0}
      :error -> {:error, missing}
    end
  end

  @doc false
  # `bspatch OLD NEW PATCH`, the default `:apply_patch`.
  @spec bspatch(Path.t(), Path.t(), Path.t()) :: :ok | {:error, term()}
  def bspatch(old, delta, new) do
    case System.find_executable("bspatch") do
      nil ->
        {:error, :bspatch_not_found}

      bspatch ->
        case System.cmd(bspatch, [old, new, delta], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> {:error, {:apply_delta_failed, status, output}}
        end
    end
  end
end
