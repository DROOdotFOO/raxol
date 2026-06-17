defmodule Raxol.Core.Stores.Naming do
  @moduledoc """
  Derive a store's identity from its registered process name.

  ETS-backed stores name their tables after the GenServer's registered
  name so that multiple instances can coexist on one node. This helper
  reads that name and fails loudly when the store was started without
  one, since an unnamed store cannot derive stable table names.
  """

  @doc """
  Return the registered name of the calling process.

  Raises when the process was not started with a registered atom name.
  `module` only shapes the error message so it points at the store the
  caller intended to start.
  """
  @spec registered_name!(module()) :: atom()
  def registered_name!(module) when is_atom(module) do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} when is_atom(name) ->
        name

      _ ->
        raise """
        #{inspect(module)} must be started with a registered :name (an atom)
        so its ETS table(s) can be derived. Use `start_link(name: :my_store)`
        or rely on the module's default name.
        """
    end
  end
end
