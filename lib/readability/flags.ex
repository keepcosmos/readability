defmodule Readability.Flags do
  @moduledoc false
  # Readability.js's `_flags`: an integer bitmask with the same values, shared by the grab loop
  # (which removes flags between attempts) and `_prepArticle` (which reads them).

  import Bitwise

  @strip_unlikelys 0x1
  @weight_classes 0x2
  @clean_conditionally 0x4

  @type t :: non_neg_integer()
  @type flag :: :strip_unlikelys | :weight_classes | :clean_conditionally

  @doc "All flags set, as `_grabArticle` starts."
  @spec all() :: t()
  def all, do: @strip_unlikelys ||| @weight_classes ||| @clean_conditionally

  @spec active?(t(), flag()) :: boolean()
  def active?(flags, flag), do: (flags &&& value(flag)) != 0

  @spec remove(t(), flag()) :: t()
  def remove(flags, flag), do: flags &&& bnot(value(flag))

  defp value(:strip_unlikelys), do: @strip_unlikelys
  defp value(:weight_classes), do: @weight_classes
  defp value(:clean_conditionally), do: @clean_conditionally
end
