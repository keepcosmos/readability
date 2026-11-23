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

  test "a caller trapping exits gets the worker's exit reason, and no messages" do
    html = "<html><body>" <> String.duplicate("<div><p>#{String.duplicate("Text, more text. ", 20)}</p></div>", 2000)

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        Process.flag(:max_heap_size, %{size: 200_000, kill: true, error_logger: false})
        result = catch_exit(Readability.article(html))
        Process.flag(:max_heap_size, 0)
        exit({result, Process.info(self(), :messages)})
      end)

    assert_receive {:DOWN, ^ref, :process, ^pid, {:killed, {:messages, []}}}, 5000
  end

  describe "the worker's heap" do
    @unlimited %{size: 0, kill: true, error_logger: true, include_shared_binaries: false}

    test "is preallocated at one word per byte of HTML up to 2 MB" do
      html = String.duplicate("x", 2 * 1024 * 1024)
      assert Readability.Worker.spawn_opts(html, @unlimited)[:min_heap_size] == byte_size(html)
      assert Readability.Worker.spawn_opts("<p>hi</p>", @unlimited)[:min_heap_size] == 9
    end

    test "isn't preallocated for larger HTML, or for a parsed document" do
      # An 8 MB comment used to preallocate 8M words (64 MB) before parsing.
      html = "<html><body><!--" <> String.duplicate("x", 8 * 1024 * 1024) <> "--></body></html>"
      refute Keyword.has_key?(Readability.Worker.spawn_opts(html, @unlimited), :min_heap_size)

      refute Keyword.has_key?(
               Readability.Worker.spawn_opts(LazyHTML.from_document("<p>hi</p>"), @unlimited),
               :min_heap_size
             )
    end

    test "gets the caller's :max_heap_size, even no limit" do
      assert Readability.Worker.spawn_opts("<p>hi</p>", @unlimited)[:max_heap_size] == @unlimited
    end

    test "leaves room under the caller's :max_heap_size" do
      max = %{@unlimited | size: 100_000}
      assert Readability.Worker.spawn_opts(String.duplicate("x", 1_000_000), max)[:min_heap_size] == 50_000
    end

    test "large HTML still works" do
      html = "<html><body><!--" <> String.duplicate("x", 3 * 1024 * 1024) <> "--></body></html>"
      assert Readability.article(html) == {:error, :not_readable}
    end
  end
end
