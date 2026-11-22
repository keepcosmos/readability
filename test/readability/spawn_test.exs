defmodule Readability.SpawnTest do
  @moduledoc "What a caller sees of `article/2` running in a process of its own (`spawn: true`)."
  use ExUnit.Case, async: true

  @html "<html><body><article><p>#{String.duplicate("Some text here. ", 40)}</p></article></body></html>"

  test "the result is the same either way" do
    assert Readability.article(@html) == Readability.article(@html, spawn: false)
    assert Readability.article("<html></html>") == {:error, :not_readable}
  end

  test "exceptions are re-raised in the caller" do
    assert_raise FunctionClauseError, fn -> Readability.article(:not_html) end
    assert_raise Readability.Error, fn -> Readability.article!("<html></html>") end
  end

  test "a caller trapping exits gets no messages" do
    Process.flag(:trap_exit, true)
    assert {:ok, _} = Readability.article(@html)
    assert_raise FunctionClauseError, fn -> Readability.article(:not_html) end
    refute_receive _, 50
  end

  test "the caller's :max_heap_size applies to the worker" do
    html = "<html><body>" <> String.duplicate("<div><p>#{String.duplicate("Text, more text. ", 20)}</p></div>", 2000)

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: 200_000, kill: true, error_logger: false})
        Readability.article(html)
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5000
  end
end
