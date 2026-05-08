defmodule Raxol.Symphony.Evidence.Backend do
  @moduledoc """
  Behaviour for an Evidence backend.

  Each backend takes the partial `Evidence` struct, the workflow `Config`,
  and per-backend `opts`, and returns an updated struct. Failures should
  land in `evidence.errors` via `Evidence.put_error/3` rather than raising;
  exceptions are caught by `Evidence.collect/3` as a safety net but tagged
  generically.
  """

  alias Raxol.Symphony.{Config, Evidence}

  @callback collect(Evidence.t(), Config.t(), keyword()) :: Evidence.t()
end
