---
tracker:
  kind: linear
  linear:
    api_key: "$LINEAR_API_KEY"
    project_slug: "$LINEAR_PROJECT_SLUG"
  # assignee: "$LINEAR_ASSIGNEE"  # optional: limit to issues assigned to one user
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Cancelled
    - Canceled
polling:
  interval_ms: 30000
workspace:
  root: ~/code/symphony-workspaces/myrepo
hooks:
  after_create: |
    git clone --depth 1 https://github.com/your-org/your-repo .
    # add any setup commands here, e.g.:
    # npm install
    # mix deps.get
    # pip install -r requirements.txt
  before_remove: |
    echo "cleaning up workspace"
agent:
  max_concurrent_agents: 3
  max_turns: 20
  # max_concurrent_agents_by_state:
  #   "Todo": 1
  #   "In Progress": 2
codex:
  command: claude -p --dangerously-skip-permissions
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on Linear issue `{{ issue.identifier }}`.

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the issue is still in an active state.
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
2. Only stop early for a true blocker (missing required auth/permissions/secrets). If blocked, record it in a comment and move the issue to a blocked/review state.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".

Work only in the provided repository copy. Do not touch any other path.
