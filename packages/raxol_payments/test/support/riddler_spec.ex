defmodule Raxol.Payments.Test.RiddlerSpec do
  @moduledoc """
  The pinned `@riddler/spec` release the cross-repo parity tests read.

  `@riddler/spec` (axol-io/riddler-sdk `packages/spec`) is the byte-equality
  contract between Riddler, its Node SDK and `raxol_payments`: the EIP-712
  conformance fixture and the fee schedule both come from it. They are read
  from ONE published release, named in `test/fixtures/RIDDLER_SPEC_VERSION`,
  never from a sibling checkout whose state nobody pinned.

  CI unpacks `npm pack @riddler/spec@<pin>` and exports:

    * `RIDDLER_SPEC_DIR` -- the unpacked tarball root (`.../package`)
    * `CONFORMANCE_FIXTURE_PATH` -- `$RIDDLER_SPEC_DIR/conformance/conformance.json`

  Locally both are optional and their tests skip with a warning. Under CI
  (`CI` set to anything but `""`, `"0"` or `"false"`) an absent artifact is a
  failure, so a missing download cannot pass as zero vectors checked.
  """

  @version_file Path.expand("../fixtures/RIDDLER_SPEC_VERSION", __DIR__)
  @external_resource @version_file

  @doc "The pinned `@riddler/spec` version, e.g. `\"0.8.0\"`."
  @spec pinned_version() :: String.t()
  def pinned_version, do: @version_file |> File.read!() |> String.trim()

  @doc "Whether this run is CI, where an absent spec artifact must fail."
  @spec ci?() :: boolean()
  def ci?, do: System.get_env("CI") not in [nil, "", "0", "false"]

  @doc "The unpacked `@riddler/spec` tarball root from `RIDDLER_SPEC_DIR`, or nil."
  @spec dir() :: Path.t() | nil
  def dir do
    case System.get_env("RIDDLER_SPEC_DIR") do
      blank when blank in [nil, ""] -> nil
      dir -> dir
    end
  end
end
