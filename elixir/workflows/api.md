---
tracker:
  kind: jira
  jira:
    site_url: "$JIRA_SITE_URL"
    email: "$JIRA_EMAIL"
    api_token: "$JIRA_API_TOKEN"
    project_key: "$JIRA_PROJECT_KEY"
  active_states:
    - To Do
    - In Progress
    - Doing
    - UNDER REVIEW
  terminal_states:
    - Done
    - Backlog
polling:
  interval_ms: 5000
workspace:
  root: ~/code/symphony-workspaces/api
hooks:
  after_create: |
    git clone --depth 1 https://github.com/harumi-io/harumi-api .
    if command -v mise >/dev/null 2>&1; then
      mise trust && mise exec -- mix deps.get
    else
      mix deps.get
    fi
  before_remove: |
    echo "cleaning up api workspace"
agent:
  max_concurrent_agents: 5
  max_turns: 20
codex:
  command: claude --dangerously-skip-permissions
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on a Jira ticket `{{ issue.identifier }}` in the **API** repository (`harumi-io/harumi-api`).

This is an Elixir/Phoenix backend API codebase.

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

## Default posture

- Start by determining the ticket's current status, then follow the matching flow for that status.
- Start every task by opening the tracking workpad comment and bringing it up to date before doing new implementation work.
- Spend extra effort up front on planning and verification design before implementation.
- Reproduce first: always confirm the current behavior/issue signal before changing code so the fix target is explicit.
- Keep ticket metadata current (state, checklist, acceptance criteria, links).
- Treat a single persistent workpad comment as the source of truth for progress.
- Use that single workpad comment for all progress and handoff notes; do not post separate "done"/summary comments.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as non-negotiable acceptance input: mirror it in the workpad and execute it before considering the work complete.
- When meaningful out-of-scope improvements are discovered during execution, file a separate Jira issue instead of expanding scope.
- Move status only when the matching quality bar is met.
- Operate autonomously end-to-end unless blocked by missing requirements, secrets, or permissions.

## Status map

- `Backlog` -> out of scope for this workflow; do not modify.
- `To Do` -> queued; immediately transition to `In Progress` before active work.
- `In Progress` / `Doing` -> implementation actively underway.
- `UNDER REVIEW` -> PR is attached and validated; waiting on human approval.
- `Merging` -> approved by human; execute the `land` skill flow.
- `Rework` -> reviewer requested changes; planning + implementation required.
- `Done` -> terminal state; no further action required.

## Related skills

- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: keep branch updated with latest `origin/main` before handoff.
- `land`: when ticket reaches `Merging`, explicitly open and follow `.codex/skills/land/SKILL.md`.

## Workpad template

````md
## Codex Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Parent task
  - [ ] 1.1 Child task

### Acceptance Criteria

- [ ] Criterion 1

### Validation

- [ ] targeted tests: `<command>`

### Notes

- <short progress note with timestamp>

### Confusions

- <only include when something was confusing during execution>
````
