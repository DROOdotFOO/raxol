defmodule Raxol.Core.Outbound.ResponseTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Outbound.Response

  doctest Raxol.Core.Outbound.Response

  setup do
    %{ref: make_ref()}
  end

  describe "the size ceiling" do
    test "exactly the ceiling is allowed and one byte past it is refused", %{ref: ref} do
      assert {:incomplete, _acc} =
               Response.absorb(Response.new(), ref, [{:data, ref, "0123"}], 4)

      assert {:error, {:too_large, 4}} =
               Response.absorb(Response.new(), ref, [{:data, ref, "01234"}], 4)
    end

    test "the counter is cumulative across chunks and across calls", %{ref: ref} do
      {:incomplete, acc} = Response.absorb(Response.new(), ref, [{:data, ref, "012"}], 4)

      assert {:error, {:too_large, 4}} = Response.absorb(acc, ref, [{:data, ref, "34"}], 4)
    end

    test "a body refused by the ceiling is an error, not a truncated success", %{ref: ref} do
      responses = [
        {:status, ref, 200},
        {:headers, ref, []},
        {:data, ref, "0123456789"},
        {:done, ref}
      ]

      assert {:error, {:too_large, 4}} = Response.absorb(Response.new(), ref, responses, 4)
    end
  end

  describe "the content-length pre-rejection" do
    test "an announced length over the ceiling is refused before any body byte", %{ref: ref} do
      headers = [{"content-type", "application/json"}, {"content-length", "9000"}]

      assert {:error, {:too_large, 1_024}} =
               Response.absorb(Response.new(), ref, [{:headers, ref, headers}], 1_024)
    end

    test "an announced length at the ceiling is accepted", %{ref: ref} do
      headers = [{"content-length", "1024"}]

      assert {:incomplete, _acc} =
               Response.absorb(Response.new(), ref, [{:headers, ref, headers}], 1_024)
    end

    test "an absent or unparseable length leaves the streaming counter as the only bound",
         %{ref: ref} do
      for headers <- [[], [{"transfer-encoding", "chunked"}], [{"content-length", "many"}]] do
        assert {:incomplete, acc} =
                 Response.absorb(Response.new(), ref, [{:headers, ref, headers}], 4)

        assert {:error, {:too_large, 4}} = Response.absorb(acc, ref, [{:data, ref, "01234"}], 4)
      end
    end

    test "a negative length is refused rather than read as smaller than the ceiling", %{ref: ref} do
      # `Integer.parse("-5")` is `{-5, ""}` and `-5 > 1024` is false, so a
      # negative length walked straight past the pre-rejection while looking
      # like a small body.
      headers = [{"content-length", "-5"}]

      assert {:error, {:transport, :invalid_content_length}} =
               Response.absorb(Response.new(), ref, [{:headers, ref, headers}], 1_024)
    end

    test "duplicate lengths that disagree are refused, and ones that agree are not", %{ref: ref} do
      # Taking the FIRST value is the request-smuggling desync: the pair below
      # announces a body inside the ceiling and a body far past it, and which
      # one is believed decides whether the response is refused.
      conflicting = [{"content-length", "5"}, {"content-length", "9000"}]

      assert {:error, {:transport, :invalid_content_length}} =
               Response.absorb(Response.new(), ref, [{:headers, ref, conflicting}], 1_024)

      agreeing = [{"content-length", "5"}, {"content-length", "5"}]

      assert {:incomplete, _acc} =
               Response.absorb(Response.new(), ref, [{:headers, ref, agreeing}], 1_024)
    end
  end

  describe "completion" do
    test "only the terminating response yields a response", %{ref: ref} do
      responses = [{:status, ref, 201}, {:headers, ref, [{"etag", "abc"}]}, {:data, ref, "hi"}]

      assert {:incomplete, acc} = Response.absorb(Response.new(), ref, responses, 1_024)
      assert_raise FunctionClauseError, fn -> Response.to_response(acc) end

      assert {:complete, acc} = Response.absorb(acc, ref, [{:done, ref}], 1_024)

      assert %{status: 201, headers: [{"etag", "abc"}], body: "hi"} = Response.to_response(acc)
    end

    test "headers and chunks come back in arrival order", %{ref: ref} do
      responses = [
        {:status, ref, 200},
        {:headers, ref, [{"a", "1"}, {"b", "2"}]},
        {:data, ref, "one"},
        {:data, ref, "two"},
        {:done, ref}
      ]

      assert {:complete, acc} = Response.absorb(Response.new(), ref, responses, 1_024)

      assert %{headers: [{"a", "1"}, {"b", "2"}], body: "onetwo"} = Response.to_response(acc)
    end

    test "a terminating response with no status is a failed read, not a response", %{ref: ref} do
      # Completing on it produced `status: nil`, which every consumer compares
      # as if it were an integer: `nil in 200..299` is false and `nil >= 500`
      # is TRUE, so an empty result was recorded as a 5xx from the origin.
      assert {:error, {:transport, :no_status}} =
               Response.absorb(Response.new(), ref, [{:headers, ref, []}, {:done, ref}], 1_024)
    end

    test "a mid-stream error is reported as a transport reason", %{ref: ref} do
      responses = [{:status, ref, 200}, {:error, ref, :closed}, {:done, ref}]

      assert {:error, {:transport, :closed}} =
               Response.absorb(Response.new(), ref, responses, 1_024)
    end

    test "a response for another reference is ignored, not absorbed", %{ref: ref} do
      other = make_ref()

      responses = [
        {:status, other, 500},
        {:data, other, "nope"},
        {:status, ref, 200},
        {:done, ref}
      ]

      assert {:complete, acc} = Response.absorb(Response.new(), ref, responses, 1_024)
      assert %{status: 200, body: ""} = Response.to_response(acc)
    end
  end

  describe "trailers" do
    test "a trailer cannot introduce a header the response never sent", %{ref: ref} do
      # Mint delivers trailers as a SECOND `{:headers, ref, _}`, which matched
      # the header clause and merged. `content-type` is what
      # `Raxol.MCP.Client.Transport.Http` reads back with `List.keyfind/3` to
      # choose between the SSE and the JSON parse path, and `mcp-session-id`
      # the same way, so a server could set either AFTER its body.
      responses = [
        {:status, ref, 200},
        {:headers, ref, [{"content-type", "application/json"}]},
        {:data, ref, "{}"},
        {:headers, ref, [{"content-type", "text/event-stream"}, {"mcp-session-id", "forged"}]},
        {:done, ref}
      ]

      assert {:complete, acc} = Response.absorb(Response.new(), ref, responses, 1_024)
      response = Response.to_response(acc)

      assert response.headers == [{"content-type", "application/json"}]

      assert response.trailers == [
               {"content-type", "text/event-stream"},
               {"mcp-session-id", "forged"}
             ]
    end

    test "a trailer content-length does not re-run the size check on a read body", %{ref: ref} do
      # Five bytes of body, then a trailer announcing 99999. The pre-rejection
      # ran a second time and refused the response as `{:too_large, 1024}`,
      # which `Raxol.Web3.HTTP` records as neither breaker success nor
      # failure: an origin appending one trailer per response was permanently
      # exempt from health accounting.
      responses = [
        {:status, ref, 200},
        {:headers, ref, []},
        {:data, ref, "hello"},
        {:headers, ref, [{"content-length", "99999"}]},
        {:done, ref}
      ]

      assert {:complete, acc} = Response.absorb(Response.new(), ref, responses, 1_024)
      assert %{status: 200, body: "hello"} = Response.to_response(acc)
    end

    test "an informational response's headers are headers, not trailers", %{ref: ref} do
      # A 1xx arrives as a status and a header block of its own, and the real
      # response follows. Telling trailers apart by "the second header block"
      # without resetting on the status files the real headers as trailers and
      # leaves the caller reading the 1xx's.
      responses = [
        {:status, ref, 103},
        {:headers, ref, [{"link", "</s.css>; rel=preload"}]},
        {:status, ref, 200},
        {:headers, ref, [{"content-type", "text/html"}]},
        {:done, ref}
      ]

      assert {:complete, acc} = Response.absorb(Response.new(), ref, responses, 1_024)
      response = Response.to_response(acc)

      assert response.status == 200
      assert response.trailers == []

      assert response.headers == [
               {"link", "</s.css>; rel=preload"},
               {"content-type", "text/html"}
             ]
    end
  end
end
