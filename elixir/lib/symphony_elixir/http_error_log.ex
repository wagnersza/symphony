defmodule SymphonyElixir.HttpErrorLog do
  @moduledoc """
  Shared helpers for safely summarizing HTTP error bodies for logging.
  """

  @max_error_body_log_bytes 1_000

  @spec summarize_body(term()) :: String.t()
  def summarize_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate()
    |> inspect()
  end

  def summarize_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate()
  end

  defp truncate(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
