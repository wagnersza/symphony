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
end
