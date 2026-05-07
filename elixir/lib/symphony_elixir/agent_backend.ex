defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Picks the agent AppServer module based on runtime config.

  The `agent.backend` config field selects between `:codex` (default) and
  `:claude`. The returned module exposes the shared AppServer interface
  (`start_session/2`, `run_turn/4`, `stop_session/1`) consumed by
  `SymphonyElixir.AgentRunner`.
  """

  alias SymphonyElixir.Config

  @spec app_server_module() :: module()
  def app_server_module do
    case Config.settings!().agent.backend do
      :claude -> SymphonyElixir.Claude.AppServer
      _ -> SymphonyElixir.Codex.AppServer
    end
  end
end
