defmodule SymphonyElixir.Jira.Adapter do
  @moduledoc """
  Jira Cloud REST v3 tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Jira.Client

  @impl true
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @impl true
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @impl true
  def fetch_issue_states_by_ids(ids), do: client_module().fetch_issue_states_by_ids(ids)

  @impl true
  def create_comment(issue_key, body) when is_binary(issue_key) and is_binary(body) do
    case client_module().request(:post, "/issue/#{issue_key}/comment", %{"body" => Client.adf_from_text(body)}, []) do
      {:ok, _} -> :ok
      {:error, _reason} -> {:error, :comment_create_failed}
    end
  end

  @impl true
  def update_issue_state(issue_key, state_name)
      when is_binary(issue_key) and is_binary(state_name) do
    target = normalize(state_name)

    with {:ok, %{"transitions" => transitions} = response} <-
           client_module().request(:get, "/issue/#{issue_key}/transitions?expand=transitions.fields", nil, []),
         current = get_in(response, ["fields", "status", "name"]) do
      if is_binary(current) and normalize(current) == target do
        :ok
      else
        case find_transition(transitions, target) do
          nil ->
            {:error, :state_not_found}

          %{"id" => id} ->
            case client_module().request(:post, "/issue/#{issue_key}/transitions", %{"transition" => %{"id" => id}}, []) do
              {:ok, _} -> :ok
              {:error, _} -> {:error, :issue_update_failed}
            end
        end
      end
    else
      {:ok, _other} -> {:error, :state_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_transition(transitions, target) when is_list(transitions) do
    Enum.find(transitions, fn
      %{"to" => %{"name" => name}} when is_binary(name) -> normalize(name) == target
      _ -> false
    end)
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()

  defp client_module do
    Application.get_env(:symphony_elixir, :jira_client_module, Client)
  end
end
