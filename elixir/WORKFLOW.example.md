---
tracker:
  kind: jira
  jira:
    site_url: "$JIRA_SITE_URL"
    email: "$JIRA_EMAIL"
    api_token: "$JIRA_API_TOKEN"
    project_key: "$JIRA_PROJECT_KEY"
  # assignee: "$JIRA_ASSIGNEE"  # optional: limit to issues assigned to one user
  active_states:
    - To Do
    - In Progress
    - Doing
  terminal_states:
    - Done
    - Backlog
polling:
  interval_ms: 30000
workspace:
  root: ~/code/symphony-workspaces
agent:
  max_concurrent_agents: 5
  max_turns: 20
  # max_concurrent_agents_by_state:
  #   "To Do": 2
  #   "In Progress": 3
codex:
  command: claude --dangerously-skip-permissions
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on a Jira ticket `{{ issue.identifier }}`.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets.
{% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in the workpad and move the issue according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.
