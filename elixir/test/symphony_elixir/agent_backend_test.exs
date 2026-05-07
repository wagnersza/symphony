defmodule SymphonyElixir.AgentBackendTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentBackend
  alias SymphonyElixir.Workflow

  setup do
    workflow_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-backend-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workflow_root)
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    Workflow.set_workflow_file_path(workflow_file)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :workflow_file_path)
      Application.delete_env(:symphony_elixir, :workflow_config)
      File.rm_rf(workflow_root)
    end)

    {:ok, workflow_file: workflow_file}
  end

  test "returns Codex.AppServer when backend is :codex", %{workflow_file: workflow_file} do
    write_workflow_with_backend(workflow_file, :codex)
    assert AgentBackend.app_server_module() == SymphonyElixir.Codex.AppServer
  end

  test "returns Claude.AppServer when backend is :claude", %{workflow_file: workflow_file} do
    write_workflow_with_backend(workflow_file, :claude)
    assert AgentBackend.app_server_module() == SymphonyElixir.Claude.AppServer
  end

  test "defaults to Codex.AppServer when backend is not specified", %{workflow_file: workflow_file} do
    write_workflow_with_backend(workflow_file, nil)
    assert AgentBackend.app_server_module() == SymphonyElixir.Codex.AppServer
  end

  defp write_workflow_with_backend(path, backend) do
    backend_yaml =
      case backend do
        :codex -> "backend: codex"
        :claude -> "backend: claude"
        nil -> ""
      end

    workflow = """
    ---
    tracker:
      kind: linear
      api_key: token
      project_slug: project
    polling:
      interval_ms: 30000
    workspace:
      root: /tmp/symphony_workspaces
    agent:
      max_concurrent_agents: 10
      max_turns: 20
      max_retry_backoff_ms: 300000
      #{backend_yaml}
    codex:
      command: codex app-server
    hooks:
      timeout_ms: 60000
    observability:
      dashboard_enabled: true
      refresh_ms: 1000
      render_interval_ms: 16
    ---
    You are an agent.
    """

    File.write!(path, workflow)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
    :ok
  end
end
