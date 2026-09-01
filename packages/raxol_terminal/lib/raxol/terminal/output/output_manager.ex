defmodule Raxol.Terminal.Output.Manager do
  @moduledoc """
  Manages terminal output buffering, event processing, styling, and formatting.
  This module handles output events, applies styles and formatting rules, and tracks metrics.
  """

  @type style :: %{
          foreground: String.t() | nil,
          background: String.t() | nil,
          bold: boolean(),
          italic: boolean(),
          underline: boolean()
        }

  @type event :: %{
          content: String.t(),
          style: String.t(),
          timestamp: integer(),
          priority: integer()
        }

  @type format_rule :: (String.t() -> String.t())

  @type metrics :: %{
          processed_events: non_neg_integer(),
          batch_count: non_neg_integer(),
          format_applications: non_neg_integer(),
          style_applications: non_neg_integer()
        }

  @type buffer :: %{
          events: [event()],
          max_size: non_neg_integer()
        }

  defstruct buffer: %{events: [], max_size: 1024 * 1024},
            format_rules: [],
            style_map: %{},
            batch_size: 100,
            metrics: %{
              processed_events: 0,
              batch_count: 0,
              format_applications: 0,
              style_applications: 0
            }

  @type t :: %__MODULE__{
          buffer: buffer(),
          format_rules: [format_rule()],
          style_map: %{String.t() => style()},
          batch_size: pos_integer(),
          metrics: metrics()
        }

  @doc """
  Creates a new output manager instance.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    buffer_size = Keyword.get(opts, :buffer_size, 1024 * 1024)
    batch_size = Keyword.get(opts, :batch_size, 100)

    %__MODULE__{
      buffer: %{events: [], max_size: buffer_size},
      format_rules: [
        &strip_ansi_codes/1,
        &normalize_whitespace/1,
        &apply_basic_formatting/1
      ],
      style_map: %{
        "default" => %{
          foreground: nil,
          background: nil,
          bold: false,
          italic: false,
          underline: false
        }
      },
      batch_size: batch_size
    }
  end

  @doc """
  Processes a single output event.
  Returns {:ok, updated_manager} or {:error, :invalid_event}.
  """
  @spec process_output(t(), event()) :: {:ok, t()} | {:error, :invalid_event}
  def process_output(%__MODULE__{} = manager, event) do
    case validate_event(event) do
      :ok ->
        processed_event = apply_formatting_rules(manager, event)

        updated_manager = %{
          manager
          | buffer: add_event_to_buffer(manager.buffer, processed_event),
            metrics: update_metrics(manager.metrics, :processed_events)
        }

        # Increment format_applications if any formatting rules exist
        updated_manager =
          case manager.format_rules != [] do
            true ->
              %{
                updated_manager
                | metrics:
                    update_metrics(
                      updated_manager.metrics,
                      :format_applications
                    )
              }

            false ->
              updated_manager
          end

        {:ok, updated_manager}

      :error ->
        {:error, :invalid_event}
    end
  end

  @doc """
  Processes a batch of output events.
  Returns {:ok, updated_manager} or {:error, :invalid_event}.
  """
  @spec process_batch(t(), [event()]) :: {:ok, t()} | {:error, :invalid_event}
  def process_batch(%__MODULE__{} = manager, events)
      when length(events) > manager.batch_size do
    {:error, :invalid_event}
  end

  def process_batch(%__MODULE__{} = manager, events) do
    Enum.reduce_while(events, manager, fn event, acc ->
      case process_output(acc, event) do
        {:ok, updated_manager} -> {:cont, updated_manager}
        {:error, _} -> {:halt, {:error, :invalid_event}}
      end
    end)
    |> case do
      {:error, :invalid_event} ->
        {:error, :invalid_event}

      updated_manager ->
        {:ok,
         %{
           updated_manager
           | metrics: update_metrics(updated_manager.metrics, :batch_count)
         }}
    end
  end

  @doc """
  Adds a custom style to the style map.
  Returns the updated manager.
  """
  @spec add_style(t(), String.t(), style()) :: t()
  def add_style(%__MODULE__{} = manager, style_name, style)
      when is_binary(style_name) do
    %{
      manager
      | style_map: Map.put(manager.style_map, style_name, style),
        metrics: update_metrics(manager.metrics, :style_applications)
    }
  end

  @doc """
  Adds a custom formatting rule.
  Returns the updated manager.
  """
  @spec add_format_rule(t(), format_rule()) :: t()
  def add_format_rule(%__MODULE__{} = manager, rule)
      when is_function(rule, 1) do
    %{
      manager
      | format_rules: [rule | manager.format_rules],
        metrics: update_metrics(manager.metrics, :format_applications)
    }
  end

  @doc """
  Gets the current metrics.
  """
  @spec get_metrics(t()) :: metrics()
  def get_metrics(%__MODULE__{} = manager) do
    manager.metrics
  end

  @doc """
  Flushes the output buffer.
  Returns the updated manager with an empty buffer.
  """
  @spec flush_buffer(t()) :: t()
  def flush_buffer(%__MODULE__{} = manager) do
    %{manager | buffer: %{manager.buffer | events: []}}
  end

  # Private functions

  @spec validate_event(event()) :: :ok | :error
  defp validate_event(%{
         content: content,
         style: style,
         timestamp: timestamp,
         priority: priority
       })
       when is_binary(content) and
              is_binary(style) and
              is_integer(timestamp) and timestamp >= 0 and
              is_integer(priority) and priority >= 0 do
    :ok
  end

  defp validate_event(_), do: :error

  @spec apply_formatting_rules(t(), event()) :: event()
  defp apply_formatting_rules(%__MODULE__{} = manager, event) do
    processed_content =
      Enum.reduce(manager.format_rules, event.content, fn rule, content ->
        rule.(content)
      end)

    %{event | content: processed_content}
  end

  @spec add_event_to_buffer(buffer(), event()) :: buffer()
  defp add_event_to_buffer(
         %{events: events, max_size: max_size} = buffer,
         event
       ) do
    new_events = [event | events]

    # Simple size check - in a real implementation, you might want more sophisticated buffering
    case length(new_events) * 100 > max_size do
      true ->
        # Keep only the most recent events
        kept_events = Enum.take(new_events, div(max_size, 100))
        %{buffer | events: kept_events}

      false ->
        %{buffer | events: new_events}
    end
  end

  @spec update_metrics(metrics(), atom()) :: metrics()
  defp update_metrics(metrics, key) do
    Map.update(metrics, key, 1, &(&1 + 1))
  end

  # Default formatting rules

  @spec strip_ansi_codes(String.t()) :: String.t()
  defp strip_ansi_codes(content) do
    # Regex-level stripping of CSI and OSC sequences. Not a full parser:
    # nested or malformed sequences are not handled.
    content
    |> String.replace(~r/\x1b\[[0-9;]*[a-zA-Z]/, "")
    |> String.replace(~r/\x1b\][0-9;]*[a-zA-Z]/, "")
  end

  @spec normalize_whitespace(String.t()) :: String.t()
  defp normalize_whitespace(content) do
    content
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @spec apply_basic_formatting(String.t()) :: String.t()
  defp apply_basic_formatting(content) do
    # Basic formatting - could be expanded with more sophisticated rules
    content
    # Remove markdown bold
    |> String.replace(~r/\*\*(.*?)\*\*/, "\\1")
    # Remove markdown italic
    |> String.replace(~r/\*(.*?)\*/, "\\1")
  end
end
