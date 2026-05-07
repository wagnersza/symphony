defmodule SymphonyElixir.Observability.Timeline do
  @moduledoc """
  Fixed-capacity, newest-first ring buffer of per-issue activity events.

  Internally stored newest-first in a list; when the buffer exceeds
  capacity, the oldest (tail) entry is dropped. `to_list/1` returns
  events newest-first for direct rendering.
  """

  @enforce_keys [:capacity, :events, :size]
  defstruct capacity: 500, events: [], size: 0

  @type event :: map()
  @type t :: %__MODULE__{
          capacity: pos_integer(),
          events: [event()],
          size: non_neg_integer()
        }

  @default_capacity 500

  @spec new(pos_integer()) :: t()
  def new(capacity \\ @default_capacity)

  def new(capacity) when is_integer(capacity) and capacity > 0 do
    %__MODULE__{capacity: capacity, events: [], size: 0}
  end

  def new(capacity) do
    raise ArgumentError, "capacity must be a positive integer, got: #{inspect(capacity)}"
  end

  @spec append(t(), event()) :: t()
  def append(%__MODULE__{capacity: capacity, events: events, size: size} = tl, event)
      when is_map(event) do
    if size < capacity do
      %{tl | events: [event | events], size: size + 1}
    else
      trimmed = [event | events] |> Enum.take(capacity)
      %{tl | events: trimmed, size: capacity}
    end
  end

  @spec to_list(t()) :: [event()]
  def to_list(%__MODULE__{events: events}), do: events

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @spec capacity(t()) :: pos_integer()
  def capacity(%__MODULE__{capacity: capacity}), do: capacity
end
