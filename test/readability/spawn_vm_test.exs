defmodule Readability.SpawnVMTest do
  @moduledoc "The spawned worker under VM-wide settings (not async: they apply to every new process)."
  use ExUnit.Case, async: false

  test "a caller without a heap limit gets none, whatever the VM's default" do
    html = "<html><body>" <> String.duplicate("<p>Some text, okay.</p>", 20_000) <> "</body></html>"
    old = :erlang.system_flag(:max_heap_size, %{size: 100_000, kill: false, error_logger: false})

    try do
      assert {:ok, _} = Readability.article(html, spawn: true)
    after
      :erlang.system_flag(:max_heap_size, old)
    end
  end
end
