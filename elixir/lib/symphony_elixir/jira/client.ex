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

  require Logger
  alias SymphonyElixir.{Config, HttpErrorLog}
  alias SymphonyElixir.Tracker.Issue

  @spec request(atom(), String.t(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def request(method, path, body \\ nil, opts \\ []) when is_atom(method) and is_binary(path) do
    jira = Config.settings!().tracker.jira
    request_fun = Keyword.get(opts, :request_fun, &default_request/4)

    with {:ok, headers} <- headers(jira),
         url = jira.site_url <> "/rest/api/3" <> path,
         {:ok, %{status: status, body: response_body}} when status in 200..299 <-
           request_fun.(method, url, headers, body) do
      {:ok, response_body}
    else
      {:ok, %{status: status, body: response_body}} ->
        Logger.error(
          "Jira API request failed status=#{status} path=#{path} body=" <>
            HttpErrorLog.summarize_body(response_body)
        )

        {:error, {:jira_api_status, status}}

      {:error, :missing_jira_credentials} = error ->
        error

      {:error, reason} ->
        Logger.error("Jira API request failed: #{inspect(reason)}")
        {:error, {:jira_api_request, reason}}
    end
  end

  defp headers(%{site_url: url, email: email, api_token: token})
       when is_binary(url) and is_binary(email) and is_binary(token) do
    encoded = Base.encode64(email <> ":" <> token)

    {:ok,
     [
       {"Authorization", "Basic " <> encoded},
       {"Accept", "application/json"},
       {"Content-Type", "application/json"}
     ]}
  end

  defp headers(_), do: {:error, :missing_jira_credentials}

  defp default_request(method, url, headers, body) do
    Req.request(
      method: method,
      url: url,
      headers: headers,
      json: body,
      connect_options: [timeout: 30_000]
    )
  end

  @priority_map %{
    "Highest" => 1,
    "High" => 2,
    "Medium" => 3,
    "Low" => 4,
    "Lowest" => 5
  }

  @spec normalize_issue(map(), String.t()) :: Issue.t()
  def normalize_issue(%{"key" => key, "fields" => fields}, site_url)
      when is_binary(key) and is_map(fields) and is_binary(site_url) do
    %Issue{
      id: key,
      identifier: key,
      title: fields["summary"],
      description: adf_to_text(fields["description"]),
      priority: map_priority(fields["priority"]),
      state: get_in(fields, ["status", "name"]),
      branch_name: derive_branch_name(key, fields["summary"]),
      url: site_url <> "/browse/" <> key,
      assignee_id: get_in(fields, ["assignee", "accountId"]),
      blocked_by: extract_blockers(fields["issuelinks"]),
      labels: extract_labels(fields["labels"]),
      assigned_to_worker: true,
      created_at: parse_datetime(fields["created"]),
      updated_at: parse_datetime(fields["updated"])
    }
  end

  defp map_priority(%{"name" => name}) when is_binary(name), do: Map.get(@priority_map, name)
  defp map_priority(_), do: nil

  defp derive_branch_name(key, summary) when is_binary(key) do
    slug_source = key <> "-" <> to_string(summary || "")

    slug =
      slug_source
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    "jira/" <> slug
  end

  defp extract_blockers(links) when is_list(links) do
    Enum.flat_map(links, fn
      %{
        "type" => %{"inward" => "is blocked by"},
        "inwardIssue" => %{
          "key" => k,
          "fields" => %{"status" => %{"name" => state}}
        }
      } ->
        [%{id: k, identifier: k, state: state}]

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp extract_labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    normalized = Regex.replace(~r/([+-]\d{2})(\d{2})$/, raw, "\\1:\\2")

    case DateTime.from_iso8601(normalized) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
