defmodule Readability.Test.DOMCompareTest do
  use ExUnit.Case, async: true

  alias Readability.Test.DOMCompare

  test "whitespace is JS's \\s: NBSP, BOM and Unicode spaces are, U+0085 (NEL) isn't" do
    assert DOMCompare.compare("<p>a \u00A0\u3000\uFEFF b</p>", "<p>a b</p>") == :ok
    assert {:mismatch, 1, _, _, _} = DOMCompare.compare("<p>ab</p>", "<p>ab\u0085</p>")
    assert {:mismatch, 1, _, _, _} = DOMCompare.compare("<p>a\u0085b</p>", "<p>a b</p>")

    assert DOMCompare.blank?(" \t\u00A0\u2028\uFEFF")
    refute DOMCompare.blank?("\u0085")
    assert DOMCompare.js_trim("\u0085x\u3000 ") == "\u0085x"
    assert DOMCompare.collapse("a\u0085 \u00A0b") == "a\u0085 b"
  end

  test "attributes whose name isn't an XML name are skipped in :content mode only" do
    assert DOMCompare.compare(~S(<p @click="x">a</p>), "<p>a</p>") == :ok
    assert {:mismatch, 0, _, _, _} = DOMCompare.compare(~S(<p @click="x">a</p>), "<p>a</p>", :attributes)
    assert DOMCompare.compare(~S(<p @click="x">a</p>), ~S(<p @click="x">a</p>), :attributes) == :ok
  end
end
