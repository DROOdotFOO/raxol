defmodule Raxol.System.EnvironmentAdapterBehaviour do
  @moduledoc """
  A behaviour for abstracting system environment interactions.
  """

  @callback get_env(variable :: String.t()) :: String.t() | nil
  @callback cmd(
              command :: String.t(),
              args :: [String.t()],
              options :: Keyword.t()
            ) :: {String.t(), non_neg_integer()} | {:error, any()}
end
