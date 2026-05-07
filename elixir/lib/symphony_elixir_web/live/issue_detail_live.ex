defmodule SymphonyElixirWeb.IssueDetailLive do
  @moduledoc """
  Live per-issue activity timeline. Subscribes to the issue's PubSub
  topic and renders each incoming event newest-first via LiveView streams.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.ObservabilityPubSub

  @impl true
  def mount(%{"identifier" => identifier}, _session, socket) do
    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe_issue(identifier)
      :ok = ObservabilityPubSub.subscribe()
    end

    snapshot = Orchestrator.issue_snapshot(identifier)

    socket =
      socket
      |> assign(:identifier, identifier)
      |> assign_snapshot(snapshot)
      |> stream(:timeline, initial_timeline(snapshot), dom_id: &timeline_dom_id/1)

    {:ok, socket}
  end

  @impl true
  def handle_info({:timeline_event, event}, socket) do
    {:noreply, stream_insert(socket, :timeline, event, at: 0)}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    snapshot = Orchestrator.issue_snapshot(socket.assigns.identifier)
    {:noreply, assign_snapshot(socket, snapshot)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Observability</p>
            <h1 class="hero-title"><%= @identifier %></h1>
            <%= if @header do %>
              <p class="hero-copy">
                <strong>State:</strong> <%= @header.state || "—" %>
                · <strong>Turn:</strong> <%= @header.turn_count %>
                · <strong>Tokens:</strong>
                <%= @header.codex_input_tokens %> in /
                <%= @header.codex_output_tokens %> out
              </p>
            <% else %>
              <p class="hero-copy">No active session for <%= @identifier %>.</p>
            <% end %>
          </div>
        </div>
      </header>

      <section class="timeline-card" id="timeline" phx-update="stream">
        <div :for={{dom_id, ev} <- @streams.timeline} id={dom_id} class={"timeline-row kind-#{ev.kind}"}>
          <span class="timeline-time"><%= format_time(ev.at) %></span>
          <span class="timeline-kind"><%= ev.kind %></span>
          <span class="timeline-summary"><%= ev.summary %></span>
        </div>
      </section>
    </section>
    """
  end

  defp assign_snapshot(socket, {:ok, snap}), do: assign(socket, :header, snap)
  defp assign_snapshot(socket, _), do: assign(socket, :header, nil)

  defp initial_timeline({:ok, %{timeline: timeline}}) when is_list(timeline), do: timeline
  defp initial_timeline(_), do: []

  defp timeline_dom_id(%{seq: seq}), do: "event-#{seq}"

  defp format_time(%DateTime{} = dt) do
    dt
    |> DateTime.to_time()
    |> Time.to_string()
    |> String.slice(0, 8)
  end

  defp format_time(_), do: ""
end
