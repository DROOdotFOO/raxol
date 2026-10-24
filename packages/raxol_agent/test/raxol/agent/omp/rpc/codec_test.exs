defmodule Raxol.Agent.OMP.RPC.CodecTest do
  # Pure decoder tests. Every line here is SYNTHETIC (malformed lines,
  # artificial chunk splits, dialogs no fixture records); recorded traffic
  # goes through `Raxol.Agent.OMP.RPCTest`.
  use ExUnit.Case, async: true

  alias Raxol.Agent.OMP.RPC.Codec

  @limit 1_024

  # The frame's JSON split into `size`-byte chunk lines (the last one shorter).
  defp chunks(frame, id, size) do
    bytes = Jason.encode!(frame)

    parts =
      for start <- 0..(byte_size(bytes) - 1)//size,
          do: binary_part(bytes, start, min(size, byte_size(bytes) - start))

    for {part, index} <- Enum.with_index(parts) do
      Jason.encode!(%{
        "type" => "rpc_chunk",
        "chunkId" => id,
        "index" => index,
        "count" => length(parts),
        "byteLength" => byte_size(bytes),
        "data" => Base.encode64(part)
      })
    end
  end

  defp feed(decoder, lines) do
    {results, decoder} =
      Enum.reduce(lines, {[], decoder}, fn line, {results, decoder} ->
        case Codec.decode_line(decoder, line) do
          {:ok, frame, decoder} -> {[{:ok, frame} | results], decoder}
          {:more, decoder} -> {results, decoder}
          {:error, reason, decoder} -> {[{:error, reason} | results], decoder}
        end
      end)

    {Enum.reverse(results), decoder}
  end

  describe "decode_line/2" do
    test "a malformed line is dropped and the next line still decodes" do
      decoder = Codec.decoder(@limit)

      assert {[
                {:error, :invalid_frame},
                {:error, :invalid_frame},
                {:ok, %{"type" => "agent_start"}}
              ], _decoder} =
               feed(decoder, ["{not json", ~s(["an", "array"]), ~s({"type":"agent_start"})])
    end

    test "a chunk run is reassembled into one frame" do
      frame = %{"id" => "7", "type" => "response", "data" => String.duplicate("é", 40)}

      assert {[{:ok, ^frame}], %{chunk: nil}} =
               feed(Codec.decoder(@limit), chunks(frame, "rpc-1", 16))
    end

    test "a run that skips an index is dropped" do
      [first, _second | rest] =
        chunks(%{"type" => "x", "pad" => String.duplicate("a", 64)}, "c", 16)

      assert {[{:error, :chunk_interrupted} | _], _decoder} =
               feed(Codec.decoder(@limit), [first | rest])
    end

    test "a frame between two chunks drops the run and itself" do
      [first, second | _] = chunks(%{"type" => "x", "pad" => String.duplicate("a", 64)}, "c", 16)
      decoder = Codec.decoder(@limit)

      assert {[{:error, :chunk_interrupted}, {:error, :chunk_interrupted}], %{chunk: nil}} =
               feed(decoder, [first, ~s({"type":"agent_start"}), second])
    end

    test "a run larger than the limit is refused at its first chunk" do
      [first | _] = chunks(%{"type" => "x", "pad" => String.duplicate("a", 2_048)}, "c", 512)

      assert {:error, :chunk_too_large, %{chunk: nil}} =
               Codec.decode_line(Codec.decoder(@limit), first)
    end

    test "a run whose bytes do not add up to byteLength is refused" do
      lines =
        for line <- chunks(%{"type" => "x"}, "c", 4) do
          line |> Jason.decode!() |> Map.update!("byteLength", &(&1 + 1)) |> Jason.encode!()
        end

      assert {[{:error, :chunk_length_mismatch}], _decoder} = feed(Codec.decoder(@limit), lines)
    end

    test "a run claiming more chunks than byteLength + 1 is refused at its first chunk" do
      empty =
        Jason.encode!(%{
          "type" => "rpc_chunk",
          "chunkId" => "c",
          "index" => 0,
          "count" => 3,
          "byteLength" => 1,
          "data" => ""
        })

      assert {:error, :invalid_chunk, %{chunk: nil}} =
               Codec.decode_line(Codec.decoder(@limit), empty)
    end

    test "a run that is not UTF-8 or not base64 is refused" do
      bad_utf8 =
        Jason.encode!(%{
          "type" => "rpc_chunk",
          "chunkId" => "c",
          "index" => 0,
          "count" => 1,
          "byteLength" => 2,
          "data" => Base.encode64(<<0xFF, 0xFE>>)
        })

      bad_base64 = String.replace(bad_utf8, Base.encode64(<<0xFF, 0xFE>>), "!!")

      assert {[{:error, :chunk_not_utf8}, {:error, :invalid_chunk}], _decoder} =
               feed(Codec.decoder(@limit), [bad_utf8, bad_base64])
    end
  end

  describe "ready/1" do
    test "takes the limits, capping a line at 8 MiB and reassembly at 64 MiB" do
      frame = %{
        "type" => "ready",
        "protocolVersion" => 1,
        "supportedProtocolVersions" => [1, 2],
        "maxFrameBytes" => 1_048_576,
        "maxReassembledFrameBytes" => 1_000_000_000
      }

      assert {:ok, %{max_frame_bytes: 1_048_576, max_reassembled_bytes: 67_108_864}} =
               Codec.ready(frame)

      assert {:ok, %{max_frame_bytes: 8_388_608}} =
               Codec.ready(%{frame | "maxFrameBytes" => 1_000_000_000})
    end

    test "refuses a frame without protocol v2 or without limits" do
      frame = %{
        "type" => "ready",
        "supportedProtocolVersions" => [1],
        "maxFrameBytes" => 1,
        "maxReassembledFrameBytes" => 1
      }

      assert {:error, :unsupported_protocol} = Codec.ready(frame)
      assert {:error, :invalid_ready_frame} = Codec.ready(Map.delete(frame, "maxFrameBytes"))
      assert {:error, :invalid_ready_frame} = Codec.ready(%{"ready" => true})
    end
  end

  describe "encode_command/1" do
    test "encodes all but the id, and frame/2 splices the id in" do
      assert {:ok, "get_state", encoded} = Codec.encode_command(%{type: "get_state"})

      assert %{"id" => "3", "type" => "get_state"} =
               "3" |> Codec.frame(encoded) |> IO.iodata_to_binary() |> Jason.decode!()
    end

    test "refuses what OMP would never answer, naming only the reason" do
      assert {:error, {:invalid_request, :type}} = Codec.encode_command(%{"message" => "hi"})
      assert {:error, {:invalid_request, :type}} = Codec.encode_command(%{"type" => ""})

      assert {:error, {:invalid_request, :type}} =
               Codec.encode_command(%{"type" => "get_state", type: "abort"})

      assert {:error, {:invalid_request, :id}} =
               Codec.encode_command(%{"type" => "get_state", "id" => "1"})

      assert {:error, {:invalid_request, :not_a_command}} =
               Codec.encode_command(%{"type" => "extension_ui_response"})

      assert {:error, {:invalid_request, Jason.EncodeError}} =
               Codec.encode_command(%{"type" => "prompt", "message" => <<"x", 0xFF>>})

      assert {:error, {:invalid_request, :command}} = Codec.encode_command("get_state")
    end
  end

  test "result/1 keeps OMP's code and drops its error text and command" do
    assert {:ok, nil} = Codec.result(%{"type" => "response", "success" => true})

    response = %{
      "command" => "get_messages_page",
      "success" => false,
      "error" => "busy at /home/someone",
      "code" => "session_busy"
    }

    assert {:error, {:rpc_error, "session_busy"}} = Codec.result(response)

    # A "code" that is not a machine token is not passed on.
    assert {:error, {:rpc_error, nil}} =
             Codec.result(%{response | "code" => "busy at /home/someone"})
  end

  describe "ui_request/1" do
    defp ui(method, extra \\ %{}),
      do: Map.merge(%{"type" => "extension_ui_request", "id" => "u1", "method" => method}, extra)

    test "an approval select goes to the principal" do
      for options <- [
            ["Approve", "Deny"],
            ["Approve", "Approve bash for this session", "Deny"],
            ["Allow in this repo", "Approve Once", "Deny"]
          ] do
        assert {:approval, "u1", ^options} =
                 Codec.ui_request(ui("select", %{"options" => options}))
      end
    end

    test "every other dialog is cancelled, presentation frames need no answer" do
      assert {:dialog, "u1"} = Codec.ui_request(ui("select", %{"options" => ["Red", "Deny"]}))

      for method <- ~w(confirm input editor ask) do
        assert {:dialog, "u1"} = Codec.ui_request(ui(method))
      end

      for method <- ~w(setWidget notify setStatus setTitle set_editor_text open_url cancel) do
        assert :none = Codec.ui_request(ui(method))
      end
    end

    test "answers are extension_ui_response lines" do
      assert %{"type" => "extension_ui_response", "id" => "u1", "value" => "Deny"} =
               "u1" |> Codec.ui_answer(Codec.deny()) |> IO.iodata_to_binary() |> Jason.decode!()

      assert %{"id" => "u1", "cancelled" => true} =
               "u1" |> Codec.ui_cancel() |> IO.iodata_to_binary() |> Jason.decode!()
    end
  end
end
