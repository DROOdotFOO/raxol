defmodule Raxol.Agent.OMP.Version do
  @moduledoc """
  Compatibility check for the OMP binary against the version Raxol is tested
  with.

  Accepts `omp --version` output (`omp/X.Y.Z`) and the bare `version` string
  of the `omp auth-gateway stdio` ready line (`{"ready":true,"version":"X.Y.Z"}`).
  A different major is refused; a minor above or below the tested pin is
  accepted with a warning; the pinned minor with any patch (prereleases and
  build metadata included) is accepted silently. Pure: the caller runs the
  binary and decides how to surface a warning.
  """

  @tested "18.13.0"

  @typedoc """
  A minor above the tested pin, `{:newer_minor, found, tested}`, or below it,
  `{:older_minor, found, tested}`.
  """
  @type warning ::
          {:newer_minor, String.t(), String.t()} | {:older_minor, String.t(), String.t()}

  @typedoc "Why a version is refused."
  @type error :: :unparseable_version | {:unsupported_major, String.t(), String.t()}

  @doc "The OMP version this Raxol release is tested against."
  @spec tested() :: String.t()
  def tested, do: @tested

  @doc """
  Parse `omp/X.Y.Z` or a bare `X.Y.Z` (surrounding whitespace ignored, so raw
  `omp --version` stdout is fine). Anything else is `:unparseable_version`.
  """
  @spec parse(term()) :: {:ok, Elixir.Version.t()} | {:error, :unparseable_version}
  def parse(input) when is_binary(input) do
    case input |> String.trim() |> strip_prefix() |> Elixir.Version.parse() do
      {:ok, version} -> {:ok, version}
      :error -> {:error, :unparseable_version}
    end
  end

  def parse(_input), do: {:error, :unparseable_version}

  defp strip_prefix("omp/" <> version), do: version
  defp strip_prefix(version), do: version

  @doc """
  Parse `input` and check it against the tested pin.

  `{:ok, version, []}` for the pinned major and minor with any patch,
  `{:ok, version, [{:newer_minor, found, tested}]}` for a higher minor,
  `{:ok, version, [{:older_minor, found, tested}]}` for a lower minor, and
  `{:error, {:unsupported_major, found, tested}}` for a different major.
  """
  @spec check(term()) :: {:ok, Elixir.Version.t(), [warning()]} | {:error, error()}
  def check(input) do
    with {:ok, version} <- parse(input) do
      compare(version, Elixir.Version.parse!(@tested))
    end
  end

  defp compare(%{major: major} = version, %{major: tested_major})
       when major != tested_major,
       do: {:error, {:unsupported_major, to_string(version), @tested}}

  defp compare(%{minor: minor} = version, %{minor: tested_minor})
       when minor > tested_minor,
       do: {:ok, version, [{:newer_minor, to_string(version), @tested}]}

  defp compare(%{minor: minor} = version, %{minor: tested_minor})
       when minor < tested_minor,
       do: {:ok, version, [{:older_minor, to_string(version), @tested}]}

  defp compare(version, _tested), do: {:ok, version, []}
end
