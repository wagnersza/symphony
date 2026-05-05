defmodule SymphonyElixir.Jira.Client do
  @moduledoc """
  Thin Jira Cloud REST v3 client for polling candidate issues and
  performing comment / transition writes on behalf of the adapter.
  """

  @spec build_jql(String.t(), [String.t()], String.t() | nil) :: String.t()
  def build_jql(project_key, state_names, assignee)
      when is_binary(project_key) and is_list(state_names) do
    Enum.each(state_names, &validate_state_name!/1)

    states_clause =
      state_names
      |> Enum.map(&quote_jql_string/1)
      |> Enum.join(",")

    base = ~s|project = "#{project_key}" AND status in (#{states_clause})|

    base
    |> maybe_append_assignee(assignee)
    |> Kernel.<>(" ORDER BY created ASC")
  end

  defp maybe_append_assignee(jql, nil), do: jql
  defp maybe_append_assignee(jql, "me"), do: jql <> " AND assignee = currentUser()"

  defp maybe_append_assignee(jql, id) when is_binary(id) do
    jql <> ~s| AND assignee = "#{id}"|
  end

  defp validate_state_name!(name) when is_binary(name) do
    if String.contains?(name, "\n") do
      raise ArgumentError, "state names must not contain newlines: #{inspect(name)}"
    end

    :ok
  end

  defp quote_jql_string(value) when is_binary(value) do
    escaped = String.replace(value, ~s|"|, ~s|\\"|)
    ~s|"#{escaped}"|
  end

  @spec adf_to_text(map() | nil) :: String.t()
  def adf_to_text(nil), do: ""

  def adf_to_text(%{"type" => "doc", "content" => content}) when is_list(content) do
    content
    |> Enum.map(&render_block/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  def adf_to_text(_other), do: ""

  @spec adf_from_text(String.t()) :: map()
  def adf_from_text(body) when is_binary(body) do
    %{
      "type" => "doc",
      "version" => 1,
      "content" => [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "text" => body}]}
      ]
    }
  end

  defp render_block(%{"type" => "paragraph", "content" => content}) when is_list(content) do
    Enum.map_join(content, "", &render_inline/1)
  end

  defp render_block(%{"type" => "bulletList", "content" => items}) when is_list(items) do
    items |> Enum.map(&render_list_item("- ", &1)) |> Enum.join("\n")
  end

  defp render_block(%{"type" => "orderedList", "content" => items}) when is_list(items) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn {item, idx} -> render_list_item("#{idx}. ", item) end)
    |> Enum.join("\n")
  end

  defp render_block(other), do: inspect(other, limit: 10, printable_limit: 200)

  defp render_list_item(prefix, %{"type" => "listItem", "content" => content})
       when is_list(content) do
    body =
      content
      |> Enum.map(&render_block/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    prefix <> body
  end

  defp render_list_item(prefix, _other), do: prefix

  defp render_inline(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp render_inline(%{"type" => "hardBreak"}), do: "\n"
  defp render_inline(_other), do: ""
end
