defmodule Readability.Worker do
  @moduledoc false
  # `spawn: true`: runs the extraction in a short-lived linked process and hands back its result
  # (or raises what it raised, or exits with its exit reason).
  #
  # A binary input of up to `@max_preallocated` bytes gets a heap of two words per byte, floored
  # at `@min_preallocated` words (64 KB on 64-bit, avoiding 4-11 GCs on small pages) and capped at
  # `@max_preallocated` words (16 MB on 64-bit): the tree and its rebuilt copies need ~1.5-2 words
  # per byte, and growing step by step makes the GC copy the tree over and over (design §8).
  # Larger inputs get the default heap: on 10 MB pages preallocating saves nothing (254 vs 254 ms
  # and 139 vs 149 ms on two of them), and a heap preallocated at less than the input size makes
  # them up to 3× slower than the default heap (8 MB: 589 ms, 4 MB: 740 ms). So at most 16 MB is
  # preallocated per call, and none for a large input that is mostly comments or whitespace. The
  # garbage goes away with the process, unscanned.
  @min_preallocated 8 * 1024
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
        unlink(pid)
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
          size = html |> byte_size() |> Kernel.*(2) |> max(@min_preallocated) |> min(@max_preallocated)
          [min_heap_size: min(size, limit)]

        _ ->
          []
      end

    # Even a size of 0: without the option the process gets the VM's default limit, which may be
    # smaller than the heap asked for (and then `spawn_opt` raises).
    heap ++ [max_heap_size: max_heap]
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
