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
        {:headers, ref, [{"c", "3"}]},
        {:data, ref, "two"},
        {:done, ref}
      ]

      assert {:complete, acc} = Response.absorb(Response.new(), ref, responses, 1_024)

      assert %{headers: [{"a", "1"}, {"b", "2"}, {"c", "3"}], body: "onetwo"} =
               Response.to_response(acc)
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
end
