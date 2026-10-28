defmodule Raxol.Payments.Test.XochiSpec do
  @moduledoc """
  The pinned `@xochi/spec` release the cross-repo parity tests read.

  `@xochi/spec` (xochi-fi/xochi-sdk `packages/spec`) is the byte-equality
  contract between Riddler, its Node SDK and `raxol_payments`: the EIP-712
  conformance fixture and fee schedule come from one published release.

  `scripts/fetch_xochi_spec.sh` reads the committed version and integrity,
  verifies the tarball before extraction, validates the package identity and
  exports one package root through `XOCHI_SPEC_DIR`. Both parity suites derive
  their files from that root; there is no second fixture-path variable or
  sibling-checkout fallback.

  Locally the root is optional and its tests skip with a warning. Under CI
  (`CI` set to anything but `""`, `"0"` or `"false"`) an absent artifact is a
  failure, so a missing download cannot pass as zero vectors checked.
  """

  @version_file Path.expand("../fixtures/XOCHI_SPEC_VERSION", __DIR__)
  @external_resource @version_file
  @required_files ["conformance/conformance.json", "fee/schedule.json"]

  @doc "The pinned `@xochi/spec` version."
  @spec pinned_version() :: String.t()
  def pinned_version, do: @version_file |> File.read!() |> String.trim()

  @doc "Whether this run is CI, where an absent spec artifact must fail."
  @spec ci?() :: boolean()
  def ci?, do: System.get_env("CI") not in [nil, "", "0", "false"]

  @doc "The validated `@xochi/spec` package root from `XOCHI_SPEC_DIR`, or nil."
  @spec dir() :: Path.t() | nil
  def dir do
    case System.get_env("XOCHI_SPEC_DIR") do
      blank when blank in [nil, ""] -> nil
      root -> validate_root!(root)
    end
  end

  @doc "The conformance fixture inside the validated package root, or nil."
  @spec conformance_path() :: Path.t() | nil
  def conformance_path do
    case dir() do
      nil -> nil
      root -> Path.join(root, "conformance/conformance.json")
    end
  end

  defp validate_root!(root) do
    manifest_path = Path.join(root, "package.json")

    unless File.regular?(manifest_path) do
      raise "XOCHI_SPEC_DIR=#{inspect(root)} is missing package.json"
    end

    manifest = manifest_path |> File.read!() |> Jason.decode!()
    version = pinned_version()

    unless {manifest["name"], manifest["version"]} == {"@xochi/spec", version} do
      raise "XOCHI_SPEC_DIR=#{inspect(root)} is not @xochi/spec@#{version}"
    end

    Enum.each(@required_files, fn relative ->
      unless File.regular?(Path.join(root, relative)) do
        raise "XOCHI_SPEC_DIR=#{inspect(root)} is missing #{relative}"
      end
    end)

    root
  end
end
