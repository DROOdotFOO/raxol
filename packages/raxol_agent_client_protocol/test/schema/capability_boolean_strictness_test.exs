# Regression: DROOdotFOO #624 review MEDIUM/LOW (schema strictness).
#
#   * Capability boolean fields were decoded with a bare
#     `Map.get(map, key, false)`, so a truthy-in-Elixir non-boolean wire value
#     (`0`, `""`, `"false"`, `[]`, a nested object) silently ENABLED the
#     capability. The fix (`AgentTypes.decode_bool/2`) is least-permissive:
#     only a literal boolean survives; anything else reads as `false`.
#
# (The review also flagged `Version.from_json`/`coerce` accepting an
# unsupported-high integer; that is by-design faithful decode -- negotiation
# happens at the response layer, the agent replies with the version it speaks
# -- and is already covered end-to-end by `wire_torture_test.exs`'s
# "forward-compat skew" handshake test. No change; not re-tested here.)
defmodule Raxol.AgentClientProtocol.Schema.CapabilityBooleanStrictnessTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    AgentCapabilities,
    McpCapabilities,
    PromptCapabilities,
    SessionCapabilities
  }

  describe "capability booleans reject non-boolean wire values (least-permissive)" do
    test "PromptCapabilities: 0 / \"\" / \"false\" do not enable" do
      assert {:ok, caps} =
               PromptCapabilities.from_json(%{
                 "image" => 0,
                 "audio" => "",
                 "embeddedContext" => "false"
               })

      refute caps.image, "integer 0 must not enable image"
      refute caps.audio, "empty string must not enable audio"
      refute caps.embedded_context, "the string \"false\" must not enable embeddedContext"
    end

    test "PromptCapabilities: a literal true still enables" do
      assert {:ok, caps} = PromptCapabilities.from_json(%{"image" => true})
      assert caps.image
    end

    test "McpCapabilities: an empty list does not enable http" do
      assert {:ok, caps} = McpCapabilities.from_json(%{"http" => [], "sse" => true})
      refute caps.http
      assert caps.sse
    end

    test "AgentCapabilities: a non-empty string does not enable loadSession" do
      assert {:ok, caps} = AgentCapabilities.from_json(%{"loadSession" => "yes"})
      refute caps.load_session
    end

    test "SessionCapabilities: a non-boolean does not enable modes" do
      assert {:ok, caps} = SessionCapabilities.from_json(%{"modes" => 1})
      refute caps.modes
    end
  end
end
