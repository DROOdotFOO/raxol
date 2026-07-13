defmodule Raxol.Terminal.ANSI.StateMachine do
  @moduledoc """
  A state machine for parsing ANSI escape sequences.
  This module provides a more efficient alternative to regex-based parsing.
  """


  # Guard macros for ANSI byte classification
  defmacro param_byte?(byte),
    do: quote(do: unquote(byte) >= ?0 and unquote(byte) <= ?9)

  defmacro intermediate_byte?(byte),
    do: quote(do: unquote(byte) >= 0x20 and unquote(byte) <= 0x2F)

  defmacro csi_final_byte?(byte) do
    quote do
      unquote(byte) in [
        ?@,
        ?A,
        ?B,
        ?C,
        ?D,
        ?E,
        ?F,
        ?G,
        ?H,
        ?I,
        ?J,
        ?K,
        ?L,
        ?M,
        ?P,
        ?S,
        ?T,
        ?X,
        ?Z,
        ?`,
        ?a,
        ?b,
        ?c,
        ?d,
        ?e,
        ?f,
        ?g,
        ?h,
        ?j,
        ?k,
        ?l,
        ?m,
        ?n,
        ?o,
        ?p,
        ?q,
        ?r,
        ?s,
        ?t,
        ?u,
        ?v,
        ?w,
        ?x,
        ?y,
        ?z,
        ?{,
        ?|,
        ?},
        ?~
      ]
    end
  end

  defmacro cancel_byte?(byte), do: quote(do: unquote(byte) in [0x18, 0x1A])

  @type state ::
          :ground
          | :escape
          | :csi_entry
          | :csi_param
          | :csi_intermediate
          | :csi_final
          | :osc_string
          | :osc_string_maybe_st
          | :dcs_entry
          | :dcs_passthrough
          | :dcs_passthrough_maybe_st
          | :designate_charset
          | :ignore

  @type sequence_type :: :csi | :osc | :sos | :pm | :apc | :esc | :text

  @type sequence :: %{
          type: sequence_type(),
          command: String.t(),
          params: list(String.t()),
          intermediate: String.t(),
          final: String.t(),
          text: String.t()
        }

  @type parser_state :: %{
          state: state(),
          params_buffer: String.t(),
          intermediates_buffer: String.t(),
          payload_buffer: String.t(),
          final_byte: String.t() | nil,
          designating_gset: atom() | nil
        }

  @doc """
  Creates a new parser state with default values.
  """
  @spec new() :: parser_state()
  def new do
    %{
      state: :ground,
      params_buffer: "",
      intermediates_buffer: "",
      payload_buffer: "",
      final_byte: nil,
      designating_gset: nil
    }
  end

  @doc """
  Processes input bytes through the state machine.
  Returns the updated state and any parsed sequences.
  """
  @spec process(parser_state(), binary()) :: {parser_state(), list(sequence())}
  def process(state, input) do
    process_bytes(state, input, [])
  end

  defp process_bytes(state, <<>>, sequences) do
    {state, Enum.reverse(sequences)}
  end

  defp process_bytes(state, <<byte, rest::binary>>, sequences) do
    case handle_byte(state, byte) do
      {:continue, new_state} ->
        process_bytes(new_state, rest, sequences)

      {:emit, new_state, sequence} ->
        process_bytes(new_state, rest, [sequence | sequences])

      {:error, new_state, reason} ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "ANSI State Machine Error: #{inspect(reason)}",
          %{state: state, byte: byte}
        )

        process_bytes(new_state, rest, sequences)
    end
  end

  defp handle_byte(%{state: :ground} = state, byte),
    do: handle_ground_state(state, byte)

  defp handle_byte(%{state: :escape} = state, byte),
    do: handle_escape_state(state, byte)

  defp handle_byte(%{state: :csi_entry} = state, byte),
    do: handle_csi_entry_state(state, byte)

  defp handle_byte(%{state: :csi_param} = state, byte),
    do: handle_csi_param_state(state, byte)

  defp handle_byte(%{state: :csi_intermediate} = state, byte),
    do: handle_csi_intermediate_state(state, byte)

  defp handle_byte(%{state: :osc_string} = state, byte),
    do: handle_osc_string_state(state, byte)

  defp handle_byte(%{state: :osc_string_maybe_st} = state, byte),
    do: handle_osc_string_maybe_st_state(state, byte)

  defp handle_byte(%{state: :dcs_entry} = state, byte),
    do: handle_dcs_entry_state(state, byte)

  defp handle_byte(%{state: :dcs_passthrough} = state, byte),
    do: handle_dcs_passthrough_state(state, byte)

  defp handle_byte(%{state: :dcs_passthrough_maybe_st} = state, byte),
    do: handle_dcs_passthrough_maybe_st_state(state, byte)

  defp handle_byte(%{state: :designate_charset} = state, byte),
    do: handle_designate_charset_state(state, byte)

  defp handle_byte(%{state: :ignore} = state, byte),
    do: handle_ignore_state(state, byte)

  defp handle_ground_state(state, byte) do
    case byte do
      0x1B ->
        {:continue, %{state | state: :escape}}

      b when b >= 0x20 and b <= 0x7E ->
        {:emit, state,
         %{
           type: :text,
           command: "",
           params: [],
           intermediate: "",
           final: "",
           text: <<b>>
         }}

      _ ->
        {:continue, state}
    end
  end

  defp handle_escape_state(state, ?[) do
    {:continue, %{state | state: :csi_entry}}
  end

  defp handle_escape_state(state, ?]) do
    {:continue, %{state | state: :osc_string}}
  end

  defp handle_escape_state(state, ?P) do
    {:continue, %{state | state: :dcs_entry}}
  end

  defp handle_escape_state(state, byte) when byte in [?(, ?), ?*, ?+] do
    {:continue, %{state | state: :designate_charset, designating_gset: byte}}
  end

  defp handle_escape_state(state, byte) do
    case byte do
      b when cancel_byte?(b) ->
        {:continue, %{state | state: :ground}}

      # Only emit escape sequences for specific valid escape characters
      b
      when b in [
             ?@,
             ?A,
             ?B,
             ?C,
             ?D,
             ?E,
             ?F,
             ?G,
             ?H,
             ?I,
             ?J,
             ?K,
             ?L,
             ?M,
             ?N,
             ?O,
             ?P,
             ?Q,
             ?R,
             ?S,
             ?T,
             ?U,
             ?V,
             ?W,
             ?X,
             ?Y,
             ?Z,
             ?[,
             ?\\,
             ?],
             ?^,
             ?_,
             ?`,
             ?a,
             ?b,
             ?c,
             ?d,
             ?e,
             ?f,
             ?g,
             ?h,
             ?i,
             ?j,
             ?k,
             ?l,
             ?m,
             ?n,
             ?o,
             ?p,
             ?q,
             ?r,
             ?s,
             ?t,
             ?u,
             ?v,
             ?w,
             ?x,
             ?y,
             ?z,
             ?{,
             ?|,
             ?},
             ?~
           ] ->
        create_escape_sequence(state, byte)

      _ ->
        # Invalid escape sequence - transition to ignore state to consume the invalid sequence
        {:continue, %{state | state: :ignore}}
    end
  end

  defp create_escape_sequence(state, byte) do
    {:emit, %{state | state: :ground},
     %{
       type: :esc,
       command: <<byte>>,
       params: [],
       intermediate: "",
       final: "",
       text: ""
     }}
  end

  defp handle_csi_entry_state(state, ?;) do
    {:continue, %{state | state: :csi_param, params_buffer: ";"}}
  end

  defp handle_csi_entry_state(state, byte) do
    case byte do
      b when param_byte?(b) ->
        {:continue, %{state | state: :csi_param, params_buffer: <<b>>}}

      b when intermediate_byte?(b) ->
        {:continue, %{state | state: :csi_intermediate, intermediates_buffer: <<b>>}}

      b when csi_final_byte?(b) ->
        {:emit, %{state | state: :ground},
         %{
           type: :csi,
           command: <<b>>,
           params: [""],
           intermediate: "",
           final: <<b>>,
           text: ""
         }}

      b when cancel_byte?(b) ->
        # On cancel, reset buffers and return to ground state
        {:continue, %{state | state: :ground, params_buffer: "", intermediates_buffer: ""}}

      _ ->
        # On any other invalid byte, transition to ignore state to consume the invalid sequence
        {:continue, %{state | state: :ignore, params_buffer: "", intermediates_buffer: ""}}
    end
  end

  defp handle_csi_param_state(state, ?;) do
    {:continue, %{state | params_buffer: state.params_buffer <> ";"}}
  end

  defp handle_csi_param_state(state, byte) do
    case byte do
      b when param_byte?(b) ->
        {:continue, %{state | params_buffer: state.params_buffer <> <<b>>}}

      b when intermediate_byte?(b) ->
        {:continue, %{state | state: :csi_intermediate, intermediates_buffer: <<b>>}}

      b when csi_final_byte?(b) ->
        emit_csi_sequence(state, b)

      b when cancel_byte?(b) ->
        # On cancel, reset buffers and return to ground state
        {:continue, %{state | state: :ground, params_buffer: "", intermediates_buffer: ""}}

      _ ->
        # On any other invalid byte, transition to ignore state to consume the invalid sequence
        {:continue, %{state | state: :ignore, params_buffer: "", intermediates_buffer: ""}}
    end
  end

  defp handle_csi_intermediate_state(state, byte) do
    case byte do
      b when intermediate_byte?(b) ->
        {:continue, %{state | intermediates_buffer: state.intermediates_buffer <> <<b>>}}

      b when csi_final_byte?(b) ->
        emit_csi_sequence(state, b)

      b when cancel_byte?(b) ->
        # On cancel, reset buffers and return to ground state
        {:continue, %{state | state: :ground, params_buffer: "", intermediates_buffer: ""}}

      _ ->
        # On any other invalid byte, transition to ignore state to consume the invalid sequence
        {:continue, %{state | state: :ignore, params_buffer: "", intermediates_buffer: ""}}
    end
  end

  defp handle_osc_string_state(state, byte) do
    case byte do
      0x07 -> emit_osc_sequence(state)
      0x1B -> {:continue, %{state | state: :osc_string_maybe_st}}
      b -> {:continue, %{state | payload_buffer: state.payload_buffer <> <<b>>}}
    end
  end

  defp handle_osc_string_maybe_st_state(state, byte) do
    case byte do
      ?\\ ->
        emit_osc_sequence(state)

      b ->
        {:continue,
         %{
           state
           | state: :osc_string,
             payload_buffer: state.payload_buffer <> <<0x1B, b>>
         }}
    end
  end

  # DCS (Device Control String) payloads are not parsed or emitted; we only
  # need to consume them whole so unsupported/unparsable DCS never crashes
  # the machine or leaks its bytes as ground-state text/keystrokes.
  defp handle_dcs_entry_state(state, byte) do
    case byte do
      0x1B ->
        {:continue, %{state | state: :dcs_passthrough_maybe_st}}

      b when cancel_byte?(b) ->
        {:continue, %{state | state: :ground}}

      _ ->
        {:continue, %{state | state: :dcs_passthrough}}
    end
  end

  defp handle_dcs_passthrough_state(state, byte) do
    case byte do
      0x1B ->
        {:continue, %{state | state: :dcs_passthrough_maybe_st}}

      b when cancel_byte?(b) ->
        {:continue, %{state | state: :ground}}

      _ ->
        {:continue, state}
    end
  end

  defp handle_dcs_passthrough_maybe_st_state(state, byte) do
    case byte do
      ?\\ ->
        Raxol.Core.Runtime.Log.debug_with_context(
          "Discarded unparsable DCS sequence",
          %{}
        )

        {:continue, %{state | state: :ground}}

      0x1B ->
        {:continue, state}

      b when cancel_byte?(b) ->
        {:continue, %{state | state: :ground}}

      _ ->
        {:continue, %{state | state: :dcs_passthrough}}
    end
  end

  defp handle_designate_charset_state(state, byte) do
    case byte do
      b when b >= ?0 and b <= ?9 ->
        {:emit, %{state | state: :ground},
         %{
           type: :esc,
           command: <<state.designating_gset, b>>,
           params: [],
           intermediate: "",
           final: "",
           text: ""
         }}

      _ ->
        {:error, %{state | state: :ground}, :invalid_charset_sequence}
    end
  end

  defp handle_ignore_state(state, byte) do
    case byte do
      0x1B ->
        # Found escape, transition to escape state
        {:continue, %{state | state: :escape}}

      b when b in [0x18, 0x1A] ->
        # Found cancel byte, return to ground state
        {:continue, %{state | state: :ground}}

      _ ->
        # Continue ignoring this byte - consume without emitting
        {:continue, state}
    end
  end

  defp emit_csi_sequence(state, final_byte) do
    params = String.split(state.params_buffer, ";", trim: true)

    {:emit, %{state | state: :ground},
     %{
       type: :csi,
       command: <<final_byte>>,
       params: params,
       intermediate: state.intermediates_buffer,
       final: <<final_byte>>,
       text: ""
     }}
  end

  defp emit_osc_sequence(state) do
    params = String.split(state.payload_buffer, ";", trim: true)
    [cmd | rest] = params

    {:emit, %{state | state: :ground},
     %{
       type: :osc,
       command: cmd,
       params: rest,
       intermediate: "",
       final: "",
       text: Enum.join(rest, ";")
     }}
  end
end
