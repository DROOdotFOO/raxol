defmodule Raxol.Terminal.ImageTest do
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Image

  # A terminal that cannot show an image gets the refusal before any load or
  # resize: the resize shells out to ImageMagick, which used to run (and fail
  # on a missing file as `{:resize_failed, _}`) on every first render of an
  # `image` element in a headless or agent session.
  describe "display/2 without a usable protocol" do
    test "an unsupported terminal is refused before the source is read" do
      assert {:error, :unsupported_protocol} =
               Image.display("no/such/image.png",
                 protocol: :unsupported,
                 width: 12,
                 height: 2
               )
    end

    test "an unknown protocol is refused the same way" do
      assert {:error, {:unknown_protocol, :braille}} =
               Image.display("no/such/image.png", protocol: :braille, width: 12)
    end
  end
end
