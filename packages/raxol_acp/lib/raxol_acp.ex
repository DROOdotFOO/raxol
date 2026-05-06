defmodule RaxolAcp do
  @moduledoc """
  Elixir/OTP-native Agent Commerce Protocol implementation.

  This module is the OTP application entry point. The user-facing modules
  live under the `Raxol.ACP.*` namespace.

  See the README for installation and architecture overview.
  """

  @doc """
  Returns the package version string.
  """
  @spec version() :: String.t()
  def version, do: Application.spec(:raxol_acp, :vsn) |> to_string()
end
