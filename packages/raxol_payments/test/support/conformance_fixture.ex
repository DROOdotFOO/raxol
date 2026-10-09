defmodule Raxol.Payments.Test.ConformanceFixture do
  @moduledoc """
  Loader for the shared EIP-712 conformance fixture.

  The fixture is `conformance/conformance.json` in the published
  `@xochi/spec` package (xochi-fi/xochi-sdk `packages/spec`), the
  byte-equality contract between the Node SDK and `raxol_payments`. It is read
  from the release pinned in `test/fixtures/XOCHI_SPEC_VERSION` (see
  `Raxol.Payments.Test.XochiSpec`), located by exactly one variable:

      CONFORMANCE_FIXTURE_PATH=<unpacked tarball>/package/conformance/conformance.json

  There is no sibling-checkout fallback: a checkout's working tree is whatever
  branch it happens to be on, not a pinned release.

  Conformance tests are tagged `:conformance`. Locally they are excluded and
  generate zero vectors when the variable is unset; under CI an unset variable
  raises, because zero vectors there is a missing download, not coverage.
  """

  alias Raxol.Payments.Test.XochiSpec

  @env "CONFORMANCE_FIXTURE_PATH"

  @doc """
  Load the entire fixture as a list of vector maps. Raises if the
  fixture cannot be found.
  """
  @spec load!() :: [map()]
  def load! do
    path = locate_path!()
    path |> File.read!() |> Jason.decode!()
  end

  @doc """
  Filter the fixture by `"protocol"` field.

  Outside CI, returns `[]` when the fixture is absent rather than raising. The
  conformance files call this at test-module COMPILE time (`for vec <-
  by_protocol(...)` inside a `describe`), so the `:conformance` moduletag -- a
  runtime exclusion -- cannot save a raise here: the whole suite dies before a
  single test runs, which is why a local run without the fixture warns instead.

  Under CI that compile-time raise is the point: CI fetches the pinned
  `@xochi/spec` tarball, so an absent fixture means the fetch or the export
  broke, and passing with 0 vectors would report coverage that never ran.
  """
  @spec by_protocol(String.t()) :: [map()]
  def by_protocol(protocol) do
    case do_locate() do
      nil ->
        if XochiSpec.ci?(), do: raise(not_found_message())

        IO.puts(
          :stderr,
          "[conformance] fixture absent -- 0 #{protocol} vectors generated. " <>
            "Set #{@env} to the pinned @xochi/spec conformance.json to run them."
        )

        []

      _path ->
        Enum.filter(load!(), &(&1["protocol"] == protocol))
    end
  end

  @doc "Return the single vector with the given `\"name\"`."
  @spec by_name(String.t()) :: map() | nil
  def by_name(name) do
    Enum.find(load!(), &(&1["name"] == name))
  end

  @doc """
  Try to locate the fixture file. Returns `{:ok, path}` or `{:error, :not_found}`
  without raising when the variable is unset. Useful in `setup` blocks that
  conditionally skip tests.
  """
  @spec locate() :: {:ok, Path.t()} | {:error, :not_found}
  def locate do
    case do_locate() do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  # -- Internals --

  defp locate_path! do
    case do_locate() do
      nil -> raise not_found_message()
      path -> path
    end
  end

  # An explicit path that does not exist is a misconfiguration in every
  # environment, never a reason to fall back to "absent".
  defp do_locate do
    case System.get_env(@env) do
      blank when blank in [nil, ""] ->
        nil

      path ->
        if File.regular?(path) do
          path
        else
          raise "#{@env}=#{inspect(path)} does not name a file. Point it at " <>
                  "conformance/conformance.json in the unpacked " <>
                  "@xochi/spec@#{XochiSpec.pinned_version()} tarball."
        end
    end
  end

  defp not_found_message do
    version = XochiSpec.pinned_version()

    "Conformance fixture not found: #{@env} is unset. Fetch the pinned release " <>
      "(npm pack @xochi/spec@#{version} && tar xzf xochi-spec-#{version}.tgz) " <>
      "and set #{@env}=$PWD/package/conformance/conformance.json."
  end
end
