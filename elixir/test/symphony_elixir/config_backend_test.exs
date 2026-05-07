defmodule SymphonyElixir.ConfigBackendTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema.Agent

  describe "agent.backend" do
    test "defaults to :codex" do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{})
        |> Ecto.Changeset.apply_action(:insert)

      assert agent.backend == :codex
    end

    test "accepts :claude" do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{"backend" => "claude"})
        |> Ecto.Changeset.apply_action(:insert)

      assert agent.backend == :claude
    end

    test "rejects unknown backends" do
      {:error, changeset} =
        %Agent{}
        |> Agent.changeset(%{"backend" => "gemini"})
        |> Ecto.Changeset.apply_action(:insert)

      assert %{backend: [_ | _]} = errors_on(changeset)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
