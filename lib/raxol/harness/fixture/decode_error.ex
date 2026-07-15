defmodule Raxol.Harness.Fixture.DecodeError do
  @moduledoc """
  Typed decode error for a malformed harness fixture line.

  Fixture decoding is loud-reject: a structurally invalid line is a typed
  error, never a silently-skipped line or a partially-applied record (per
  `docs/proposals/in-flight/harness-ui-testing/06-projection.md` §1.2 and
  the validation-seam discipline in `harness-spec-protocol.md` §6).
  """

  defexception [:reason, :offset, :details]

  @type reason ::
          :invalid_json
          | :not_an_object
          | :missing_record_type
          | :unknown_record_type
          | :missing_field
          | :invalid_field_type
          | :invalid_field_value
          | :unknown_event_type
          | :unsupported_schema
          | :unsupported_envelope_version
          | :missing_header
          | :duplicate_header
          | :envelope_before_header
          | :blank_line
          | :file_error

  @type t :: %__MODULE__{
          reason: reason(),
          offset: pos_integer() | nil,
          details: term()
        }

  @impl true
  def message(%__MODULE__{reason: reason, offset: offset, details: details}) do
    where = if offset, do: " at line #{offset}", else: ""
    "harness fixture decode error#{where}: #{reason} (#{inspect(details)})"
  end
end
