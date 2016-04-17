defmodule Readability.HelperTest do
  use ExUnit.Case, async: true

  import Readability, only: :functions
  alias Readability.Helper

  @sample """
    <html>
      <body>
        <p>
          <font>a</fond>
          <p>
            <font>abc</font>
          </p>
        </p>
        <p>
          <font>b</font>
        </p>
      </body>
    </html>
  """

  test "change font tag to span" do
    expectred = @sample
                |> String.replace(~r/font/, "span")
                |> Floki.parse

    result = Helper.change_tag(parse(@sample), "font", "span")
    assert expectred == result
  end
end
