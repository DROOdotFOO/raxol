defmodule Raxol.Payments.Test.XochiSpec do
  @moduledoc """
  The pinned `@xochi/spec` release the cross-repo parity tests read.

  `@xochi/spec` (xochi-fi/xochi-sdk `packages/spec`) is the byte-equality
  contract between Riddler, its Node SDK and `raxol_payments`: the EIP-712
  conformance fixture and the fee schedule both come from it. They are read
  from ONE published release, named in `test/fixtures/XOCHI_SPEC_VERSION`,
  never from a sibling checkout whose state nobody pinned.

  CI unpacks `npm pack @xochi/spec@<pin>` and exports:

    * `XOCHI_SPEC_DIR` -- the unpacked tarball root (`.../package`)
    * `CONFORMANCE_FIXTURE_PATH` -- `$XOCHI_SPEC_DIR/conformance/conformance.json`

  Locally both are optional and their tests skip with a warning. Under CI
  (`CI` set to anything but `""`, `"0"` or `"false"`) an absent artifact is a
  failure, so a missing download cannot pass as zero vectors checked.
  """

  @version_file Path.expand("../fixtures/XOCHI_SPEC_VERSION", __DIR__)
  @external_resource @version_file

  @doc "The pinned `@xochi/spec` version, e.g. `\"0.8.0\"`."
  @spec pinned_version() :: String.t()
  def pinned_version, do: @version_file |> File.read!() |> String.trim()

  @doc "Whether this run is CI, where an absent spec artifact must fail."
  @spec ci?() :: boolean()
  def ci?, do: System.get_env("CI") not in [nil, "", "0", "false"]

  @doc "The unpacked `@xochi/spec` tarball root from `XOCHI_SPEC_DIR`, or nil."
  @spec dir() :: Path.t() | nil
  def dir do
    case System.get_env("XOCHI_SPEC_DIR") do
      blank when blank in [nil, ""] -> nil
      dir -> dir
    end
  end
end
