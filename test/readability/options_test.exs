defmodule Readability.OptionsTest do
  use ExUnit.Case, async: true

  alias Readability.Options

  test "validate!/1 returns a map with defaults" do
    opts = Options.validate!([])
    assert opts.char_threshold == 500
    assert opts.link_density_modifier === 0.0
  end

  test "link_density_modifier accepts integers and floats, normalized to float" do
    assert Options.validate!(link_density_modifier: 1).link_density_modifier === 1.0
    assert Options.validate!(link_density_modifier: -2).link_density_modifier === -2.0
    assert Options.validate!(link_density_modifier: 0.25).link_density_modifier === 0.25
    assert_raise NimbleOptions.ValidationError, fn -> Options.validate!(link_density_modifier: "1") end
  end
end
