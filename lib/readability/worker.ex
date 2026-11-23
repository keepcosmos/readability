defmodule Readability.Worker do
  @moduledoc false
  # `spawn: true`: runs the extraction in a short-lived linked process and hands back its result
  # (or raises what it raised, or exits with its exit reason).
  #
  # A binary input of up to `@max_preallocated` bytes gets a heap of one word per byte: the tree
  # and its rebuilt copies need about that much, and growing to it step by step makes the GC copy
  # the tree over and over (design §8). Over the 130 test pages (all under 2 MB) that's 13% less
  # time (296 → 257 ms). Larger inputs get the default heap: on 10 MB pages preallocating saves
  # nothing (254 vs 254 ms and 139 vs 149 ms on two of them), and a heap preallocated at less
  # than the input size makes them up to 3× slower than the default heap (8 MB: 589 ms, 4 MB:
  # 740 ms). So at most 16 MB is preallocated per call, and none for a large input that is mostly
  # comments or whitespace. The garbage goes away with the process, unscanned.
  @max_preallocated 2 * 1024 * 1024

  def run(fun, html) do
    caller = self()

    worker = fn ->
      result =
        try do
          {:ok, fun.()}
        catch
          kind, reason -> {:raise, kind, reason, __STACKTRACE__}
        end

      send(caller, {self(), result})
    end

    {:max_heap_size, max_heap} = Process.info(caller, :max_heap_size)
    {pid, ref} = :erlang.spawn_opt(worker, [:link, :monitor | spawn_opts(html, max_heap)])

    receive do
      {^pid, result} ->
        # No `{:EXIT, pid, :normal}` for a caller that traps exits.
        unlink(pid)
        Process.demonitor(ref, [:flush])

        case result do
          {:ok, value} -> value
          {:raise, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
        end

      # Killed (by its `:max_heap_size`, or an exit signal). Without trapping exits the link
      # has taken the caller down already.
      {:DOWN, ^ref, :process, ^pid, reason} ->
        receive do
          {:EXIT, ^pid, _} -> :ok
        after
          0 -> :ok
        end

        exit(reason)
    end
  end

  # The heap to start with, and the caller's `:max_heap_size`.
  def spawn_opts(html, max_heap) do
    heap =
      case html do
        html when is_binary(html) and byte_size(html) <= @max_preallocated ->
          # Room to grow under the caller's limit (a size of 0 is no limit).
          limit = if max_heap.size > 0, do: div(max_heap.size, 2), else: :infinity
          [min_heap_size: min(byte_size(html), limit)]

        _ ->
          []
      end

    if max_heap.size > 0, do: heap ++ [max_heap_size: max_heap], else: heap
  end

  defp unlink(pid) do
    Process.unlink(pid)

    receive do
      {:EXIT, ^pid, _} -> :ok
    after
      0 -> :ok
    end
  end
end
