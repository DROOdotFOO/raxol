# Ported (as new coverage; upstream had no dedicated content test file) from
# the conventions of the MIT `f1729/agent_client_protocol` test suite
# (c) 2025 f1729; see NOTICE.md. Targets
# Raxol.AgentClientProtocol.Schema.{Role,Annotations,TextContent,
# ImageContent,AudioContent,TextResourceContents,BlobResourceContents,
# EmbeddedResourceResource,EmbeddedResource,ResourceLink,ContentBlock}.
defmodule Raxol.AgentClientProtocol.Schema.ContentTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Schema.Annotations
  alias Raxol.AgentClientProtocol.Schema.AudioContent
  alias Raxol.AgentClientProtocol.Schema.BlobResourceContents
  alias Raxol.AgentClientProtocol.Schema.ContentBlock
  alias Raxol.AgentClientProtocol.Schema.EmbeddedResource
  alias Raxol.AgentClientProtocol.Schema.EmbeddedResourceResource
  alias Raxol.AgentClientProtocol.Schema.ImageContent
  alias Raxol.AgentClientProtocol.Schema.ResourceLink
  alias Raxol.AgentClientProtocol.Schema.Role
  alias Raxol.AgentClientProtocol.Schema.TextContent
  alias Raxol.AgentClientProtocol.Schema.TextResourceContents

  describe "Role" do
    test "encode/decode round trip" do
      assert Role.encode(:assistant) == "assistant"
      assert Role.encode(:user) == "user"
      assert Role.decode("assistant") == {:ok, :assistant}
      assert Role.decode("user") == {:ok, :user}
    end

    test "decode/1 is total: an unrecognized role never raises" do
      assert {:error, {:invalid_role, "system"}} = Role.decode("system")
      assert {:error, {:invalid_role, nil}} = Role.decode(nil)
      assert {:error, {:invalid_role, 42}} = Role.decode(42)
    end
  end

  describe "Annotations" do
    test "to_json/from_json round trip" do
      annotations = %Annotations{audience: [:user], last_modified: "2024-01-01", priority: 0.5}
      json = Annotations.to_json(annotations)

      assert json == %{
               "audience" => ["user"],
               "lastModified" => "2024-01-01",
               "priority" => 0.5
             }

      assert {:ok, decoded} = Annotations.from_json(json)
      assert decoded.audience == [:user]
      assert decoded.last_modified == "2024-01-01"
      assert decoded.priority == 0.5
    end

    test "new/0 and to_json/1 omit every absent optional field" do
      assert Annotations.to_json(Annotations.new()) == %{}
    end

    # --- Total decode + full leniency (every Annotations field is optional
    #     with x-deserialize-default-on-error / -skip-invalid-items in the
    #     schema oracle) ---

    test "from_json/1 never fails for a map input, regardless of field shapes" do
      assert {:ok, %Annotations{}} = Annotations.from_json(%{})

      assert {:ok, %Annotations{audience: nil, last_modified: nil, priority: nil}} =
               Annotations.from_json(%{
                 "audience" => "not a list",
                 "lastModified" => 123,
                 "priority" => "not a number"
               })
    end

    test "from_json/1 skips invalid roles inside audience rather than failing the field" do
      assert {:ok, %Annotations{audience: [:user, :assistant]}} =
               Annotations.from_json(%{"audience" => ["user", "system", "assistant", 42]})
    end

    test "from_json/1 folds unknown fields into _meta, merged with an explicit _meta object" do
      assert {:ok, %Annotations{_meta: meta}} =
               Annotations.from_json(%{
                 "priority" => 1.0,
                 "_meta" => %{"a" => 1},
                 "extra" => true
               })

      assert meta == %{"a" => 1, "extra" => true}
    end

    test "Jason.Encoder round-trips through real JSON" do
      annotations = %Annotations{priority: 0.9}
      encoded = Jason.encode!(annotations)
      assert {:ok, %{"priority" => 0.9}} = Jason.decode(encoded)
    end
  end

  describe "TextContent" do
    test "new/1, to_json/from_json round trip" do
      tc = TextContent.new("hello")
      json = TextContent.to_json(tc)
      assert json == %{"text" => "hello"}
      assert {:ok, %TextContent{text: "hello"}} = TextContent.from_json(json)
    end

    test "from_json/1 is total: missing/non-string text never raises" do
      assert {:error, {:missing_field, "text"}} = TextContent.from_json(%{})
      assert {:error, {:invalid_field, "text", 42}} = TextContent.from_json(%{"text" => 42})
      assert {:error, _} = TextContent.from_json("not a map")
      assert {:error, _} = TextContent.from_json(nil)
    end

    test "from_json/1 defaults a malformed annotations object to nil rather than failing" do
      assert {:ok, %TextContent{text: "x", annotations: nil}} =
               TextContent.from_json(%{"text" => "x", "annotations" => "not a map"})
    end

    test "Jason.Encoder round-trips through real JSON" do
      tc = TextContent.new("round trip me")
      encoded = Jason.encode!(tc)
      assert {:ok, %{"text" => "round trip me"}} = Jason.decode(encoded)
    end
  end

  describe "ImageContent" do
    test "new/2, to_json/from_json round trip" do
      ic = ImageContent.new("base64data", "image/png")
      json = ImageContent.to_json(ic)
      assert json == %{"data" => "base64data", "mimeType" => "image/png"}

      assert {:ok, %ImageContent{data: "base64data", mime_type: "image/png"}} =
               ImageContent.from_json(json)
    end

    test "from_json/1 is total: missing data or mimeType never raises" do
      assert {:error, {:missing_field, "data"}} =
               ImageContent.from_json(%{"mimeType" => "image/png"})

      assert {:error, {:missing_field, "mimeType"}} = ImageContent.from_json(%{"data" => "x"})
    end

    test "Jason.Encoder round-trips through real JSON" do
      ic = ImageContent.new("d", "image/jpeg")

      assert {:ok, %{"data" => "d", "mimeType" => "image/jpeg"}} =
               ic |> Jason.encode!() |> Jason.decode()
    end
  end

  describe "AudioContent" do
    test "new/2, to_json/from_json round trip" do
      ac = AudioContent.new("audiodata", "audio/wav")
      json = AudioContent.to_json(ac)

      assert {:ok, %AudioContent{data: "audiodata", mime_type: "audio/wav"}} =
               AudioContent.from_json(json)
    end

    test "from_json/1 is total: missing data or mimeType never raises" do
      assert {:error, {:missing_field, "data"}} =
               AudioContent.from_json(%{"mimeType" => "audio/wav"})
    end
  end

  describe "TextResourceContents / BlobResourceContents / EmbeddedResourceResource" do
    test "TextResourceContents round trip" do
      trc = TextResourceContents.new("hi", "file:///a.txt")
      json = TextResourceContents.to_json(trc)

      assert {:ok, %TextResourceContents{text: "hi", uri: "file:///a.txt"}} =
               TextResourceContents.from_json(json)
    end

    test "BlobResourceContents round trip" do
      brc = BlobResourceContents.new("Zm9v", "file:///a.bin")
      json = BlobResourceContents.to_json(brc)

      assert {:ok, %BlobResourceContents{blob: "Zm9v", uri: "file:///a.bin"}} =
               BlobResourceContents.from_json(json)
    end

    test "EmbeddedResourceResource dispatches on the presence of text vs blob" do
      assert {:ok, %TextResourceContents{}} =
               EmbeddedResourceResource.from_json(%{"text" => "hi", "uri" => "file:///a"})

      assert {:ok, %BlobResourceContents{}} =
               EmbeddedResourceResource.from_json(%{"blob" => "Zm9v", "uri" => "file:///a"})
    end

    test "EmbeddedResourceResource.from_json/1 is total: ambiguous/invalid input never raises" do
      assert {:error, :ambiguous_resource} =
               EmbeddedResourceResource.from_json(%{"uri" => "file:///a"})

      assert {:error, _} = EmbeddedResourceResource.from_json("not a map")
      assert {:error, _} = EmbeddedResourceResource.from_json(nil)
    end
  end

  describe "EmbeddedResource" do
    test "to_json/from_json round trip (text variant)" do
      er = EmbeddedResource.new(TextResourceContents.new("hi", "file:///a"))
      json = EmbeddedResource.to_json(er)

      assert {:ok, %EmbeddedResource{resource: %TextResourceContents{text: "hi"}}} =
               EmbeddedResource.from_json(json)
    end

    test "from_json/1 is total: missing/unparseable resource never raises" do
      assert {:error, {:missing_field, "resource"}} = EmbeddedResource.from_json(%{})
      assert {:error, _} = EmbeddedResource.from_json(%{"resource" => %{"uri" => "file:///a"}})
      assert {:error, _} = EmbeddedResource.from_json("not a map")
    end
  end

  describe "ResourceLink" do
    test "new/2, to_json/from_json round trip with all optional fields" do
      rl = %ResourceLink{name: "a.txt", uri: "file:///a.txt", size: 123, title: "A file"}
      json = ResourceLink.to_json(rl)
      assert json["name"] == "a.txt"
      assert json["size"] == 123
      assert {:ok, decoded} = ResourceLink.from_json(json)
      assert decoded.size == 123
      assert decoded.title == "A file"
    end

    test "from_json/1 is total: missing name/uri never raises" do
      assert {:error, {:missing_field, "name"}} = ResourceLink.from_json(%{"uri" => "file:///a"})
      assert {:error, {:missing_field, "uri"}} = ResourceLink.from_json(%{"name" => "a"})
    end

    test "from_json/1 defaults a wrong-typed optional field to nil rather than failing" do
      assert {:ok, %ResourceLink{size: nil}} =
               ResourceLink.from_json(%{
                 "name" => "a",
                 "uri" => "file:///a",
                 "size" => "not a number"
               })
    end
  end

  describe "ContentBlock" do
    test "text/1 round trip via to_json/from_json with the type discriminator" do
      block = ContentBlock.text(TextContent.new("hi"))
      json = ContentBlock.to_json(block)
      assert json == %{"type" => "text", "text" => "hi"}
      assert {:ok, {:text, %TextContent{text: "hi"}}} = ContentBlock.from_json(json)
    end

    test "image/1, audio/1, resource_link/1, resource/1 round trip" do
      image = ContentBlock.image(ImageContent.new("d", "image/png"))

      assert {:ok, {:image, %ImageContent{}}} =
               image |> ContentBlock.to_json() |> ContentBlock.from_json()

      audio = ContentBlock.audio(AudioContent.new("d", "audio/wav"))

      assert {:ok, {:audio, %AudioContent{}}} =
               audio |> ContentBlock.to_json() |> ContentBlock.from_json()

      link = ContentBlock.resource_link(ResourceLink.new("a", "file:///a"))

      assert {:ok, {:resource_link, %ResourceLink{}}} =
               link |> ContentBlock.to_json() |> ContentBlock.from_json()

      resource =
        ContentBlock.resource(EmbeddedResource.new(TextResourceContents.new("t", "file:///a")))

      assert {:ok, {:resource, %EmbeddedResource{}}} =
               resource |> ContentBlock.to_json() |> ContentBlock.from_json()
    end

    test "from_string/1 convenience constructor" do
      assert ContentBlock.from_string("hi") == {:text, TextContent.new("hi")}
    end

    # --- Total decode: an unrecognized/missing type has no default variant ---

    test "from_json/1 is total: unrecognized type never raises" do
      assert {:error, {:unknown_content_block_type, "video"}} =
               ContentBlock.from_json(%{"type" => "video", "data" => "x"})
    end

    test "from_json/1 is total: missing type never raises" do
      assert {:error, {:missing_field, "type"}} = ContentBlock.from_json(%{"text" => "x"})
    end

    test "from_json/1 is total: non-map input never raises" do
      assert {:error, {:invalid_content_block, "nope"}} = ContentBlock.from_json("nope")
      assert {:error, _} = ContentBlock.from_json(nil)
      assert {:error, _} = ContentBlock.from_json(42)
    end

    test "from_json/1 propagates a malformed variant body as an error, not a crash" do
      assert {:error, _} = ContentBlock.from_json(%{"type" => "text"})
      assert {:error, _} = ContentBlock.from_json(%{"type" => "image", "mimeType" => "image/png"})
    end
  end

  describe "atom safety" do
    test "no ContentBlock/Content struct decode invokes String.to_atom on wire-derived data" do
      for i <- 1..50 do
        assert {:ok, {:text, _}} =
                 ContentBlock.from_json(%{"type" => "text", "text" => "t#{i}", "field_#{i}" => i})
      end
    end
  end
end
