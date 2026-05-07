# Symphony

Symphony watches your issue tracker and autonomously works tickets end-to-end using Claude. Each ticket gets an isolated workspace, a fresh clone of the target repository, and a Claude agent that implements, tests, opens a PR, and moves the ticket through your workflow — unattended.

## How it works

1. Symphony polls your tracker (Jira or Linear) for tickets in configured active states.
2. For each eligible ticket it creates an isolated workspace directory.
3. It clones the target repository into that workspace (`hooks.after_create`).
4. It launches a Claude agent with the ticket context as the prompt.
5. The agent works until the ticket reaches a terminal state or the turn limit is hit.
6. When done, Symphony cleans up the workspace.

One Symphony process handles one workflow file (one tracker project + one repository). Run multiple processes in parallel to cover multiple repos.

---

## Prerequisites

### Elixir runtime

Install [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions:

```bash
brew install mise
```

Then inside this repo:

```bash
cd elixir
mise trust
mise install
```

### Claude CLI

Install and authenticate [Claude Code](https://claude.ai/code):

```bash
npm install -g @anthropic-ai/claude-code
claude login
```

### GitHub CLI

Required for the agent to open PRs and interact with GitHub:

```bash
brew install gh
gh auth login
```

---

## Install

Clone and build the Symphony binary:

```bash
git clone https://github.com/wagnersza/symphony
cd symphony/elixir
mise exec -- mix setup
mise exec -- mix build
```

This produces `elixir/bin/symphony`.

---

## Tracker setup

### Jira

Create a `.env` file at the root of this repo (it is gitignored):

```env
JIRA_API_TOKEN=your-jira-api-token
JIRA_EMAIL=you@your-company.com
JIRA_SITE_URL=https://your-org.atlassian.net
JIRA_PROJECT_KEY=YOUR_PROJECT_KEY
```

**Getting a Jira API token:**

1. Go to [Atlassian API tokens](https://id.atlassian.com/manage-profile/security/api-tokens)
2. Click **Create API token**, give it a name (e.g. `symphony`), and copy the value

**Board statuses Symphony expects by default:**

| Status | Role |
|--------|------|
| `To Do` | Queued — agent picks up and moves to `In Progress` |
| `In Progress` | Agent is actively working |
| `Doing` | Treated the same as `In Progress` |
| `UNDER REVIEW` | PR submitted — waiting for human review |
| `Done` | Terminal — not touched |
| `Backlog` | Terminal — not touched |

You can override `active_states` and `terminal_states` in your workflow file to match your board.

### Linear

Add to your `.env` file:

```env
LINEAR_API_KEY=lin_api_xxxxxxxxxxxxxxxxxxxx
LINEAR_PROJECT_SLUG=your-project-slug
```

**Getting a Linear API key:**

1. Go to **Settings → API → Personal API keys**
2. Click **Create key**, give it a name (e.g. `symphony`), and copy the value

**Finding your project slug:**

Open a Linear issue URL — it looks like `https://linear.app/your-org/issue/PROJ-123`. The slug is the segment after your org name (e.g. `your-org`). You can also use the team identifier shown on your Linear workspace settings.

**Default Linear states Symphony uses:**

| Status | Role |
|--------|------|
| `Todo` | Queued |
| `In Progress` | Agent is actively working |
| `Done` | Terminal |
| `Cancelled` / `Canceled` | Terminal |

---

## Workflow files

A workflow file is a Markdown file with a YAML front matter block that configures the tracker, workspace, agent limits, and hooks — followed by a Jinja2 prompt template that is sent to the agent for each ticket.

Available template variables: `{{ issue.identifier }}`, `{{ issue.title }}`, `{{ issue.state }}`, `{{ issue.description }}`, `{{ issue.labels }}`, `{{ issue.url }}`, `{{ attempt }}`.

### Jira example

```yaml
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
  terminal_states:
    - Done
    - Backlog
polling:
  interval_ms: 30000
workspace:
  root: ~/code/symphony-workspaces/myrepo
hooks:
  after_create: |
    git clone --depth 1 https://github.com/your-org/your-repo .
    npm install
agent:
  max_concurrent_agents: 3
  max_turns: 20
codex:
  command: claude -p --dangerously-skip-permissions
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on Jira ticket `{{ issue.identifier }}`: {{ issue.title }}.

...
```

See `elixir/WORKFLOW.jira.example.md` for a complete Jira starter template.

### Linear example

```yaml
---
tracker:
  kind: linear
  linear:
    api_key: "$LINEAR_API_KEY"
    project_slug: "$LINEAR_PROJECT_SLUG"
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Cancelled
polling:
  interval_ms: 30000
workspace:
  root: ~/code/symphony-workspaces/myrepo
hooks:
  after_create: |
    git clone --depth 1 https://github.com/your-org/your-repo .
    npm install
agent:
  max_concurrent_agents: 3
  max_turns: 20
codex:
  command: claude -p --dangerously-skip-permissions
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on Linear issue `{{ issue.identifier }}`: {{ issue.title }}.

...
```

See `elixir/WORKFLOW.linear.example.md` for a complete Linear starter template.

Full worked examples with hooks and agent instructions are in `elixir/workflows/`.

---

## Using agent-skills

[agent-skills](https://github.com/addyosmani/agent-skills) is a collection of production-grade engineering skills for AI coding agents. Each skill encodes the workflow a senior engineer follows for a specific phase of development — speccing, planning, implementing, testing, reviewing, and shipping. Read more on [Addy Osmani's blog](https://addyosmani.com/blog/agent-skills/).

Skills cover the full lifecycle:

| Phase | Skills used |
|-------|-------------|
| Define | `spec-driven-development` |
| Plan | `planning-and-task-breakdown` |
| Build | `incremental-implementation`, `test-driven-development`, `context-engineering` |
| Review | `code-review-and-quality`, `security-and-hardening` |
| Ship | `git-workflow-and-versioning`, `ci-cd-and-automation` |

### Installing agent-skills

```bash
/plugin marketplace add addyosmani/agent-skills
/plugin install agent-skills@addy-agent-skills
```

> If you don't have GitHub SSH keys configured, use the HTTPS URL:
> ```bash
> /plugin marketplace add https://github.com/addyosmani/agent-skills.git
> /plugin install agent-skills@addy-agent-skills
> ```

### Two-phase workflow with agent-skills

Rather than one workflow that jumps straight from ticket to PR, you can split the process into two dedicated workflows with a human review gate between them:

```
Backlog ──→ To Plan ──→ Review Plan ──→ Build ──→ In Progress ──→ In Review ──→ Done
                ▲             │                                       ▲
                │             │ (human rejects plan)                  │
                └─────────────┘                                       │
                                                                      │
            [planning.md]                       [development.md] ─────┘
            spec-driven-development             incremental-implementation
            + planning-and-task-breakdown       + test-driven-development
                                                + git-workflow-and-versioning
                                                + code-review-and-quality
```

**State responsibilities:**

| State | Owner | What happens |
|-------|-------|--------------|
| `Backlog` | human | Idea queue — no agents touch it |
| `To Plan` | planning agent | Reads ticket + attachments, writes spec + task breakdown, updates Summary/Description |
| `Review Plan` | human | Reviews the plan; accept → `Build`, reject → comment + back to `To Plan` |
| `Build` | development agent | Creates one Jira subtask per planned task, then transitions parent to `In Progress` |
| `In Progress` | development agent | Implements subtasks (parallel where dependencies allow), each subtask flips through `In Progress → Done` |
| `In Review` | human | Reviews the PR |
| `Done` | — | Terminal |
| `Cancelled` | — | Terminal |

**Why two workflows?**

- The planning agent reads code but writes no code — it can run on cheaper/faster settings.
- The development agent gets a human-reviewed spec and ordered task list before it writes a single line.
- The plan review gate catches misunderstandings before any implementation effort is spent.
- Each phase is independently retryable without losing the other's work.
- You can run multiple development agents in parallel against tickets that are already `Build`.

**Planning behaviour highlights:**

- Reads all ticket comments **and image attachments** (mockups, screenshots, diagrams) and treats them as first-class requirements.
- Updates the ticket Summary and Description in place when the original framing is vague or wrong. The Description is reserved for the durable problem statement; all progress notes go in comments.
- Posts the spec & plan as a comment when it fits within Jira's 32,767-character comment limit; otherwise attaches it as `spec-and-plan.md` and adds a short pointer comment.
- When the human rejects the plan and moves the ticket back to `To Plan`, the agent re-runs in **revision mode** — reads the feedback comments, edits the spec in place, and adds `Revision Notes` documenting how each feedback item was resolved.

**Development behaviour highlights:**

- On entering `Build`, materialises every planned task as a Jira **subtask** of the parent before writing any code. The subtask description carries the task's acceptance criteria, verification, files, dependencies, and size.
- Only after all subtasks exist does it transition the parent to `In Progress` and start coding.
- Honours `Depends on:` markers from the plan to parallelise safely — only unblocked subtasks with non-overlapping files run concurrently.
- A subtask is moved to `In Progress` only while it's actively being worked. The parent stays `In Progress` for the duration of the build phase.
- All progress, decisions, and blockers are recorded as **comments** on the parent or subtasks — never written into Descriptions.
- When all subtasks are `Done` and self-review passes, opens a PR with the `symphony` label and transitions the parent to `In Review`.

**Board setup:**

Configure your tracker workflow with these statuses: `Backlog`, `To Plan`, `Review Plan`, `Build`, `In Progress`, `In Review`, `Done`, `Cancelled`. Each agent's `active_states`/`terminal_states` in the workflow file already match this scheme.

**Running both workflows:**

```bash
source .env

# Terminal 1 — planning agent (picks up tickets in `To Plan`)
./elixir/bin/symphony elixir/workflows/planning.md --i-understand-that-this-will-be-running-without-the-usual-guardrails

# Terminal 2 — development agent (picks up tickets in `Build`)
./elixir/bin/symphony elixir/workflows/development.md --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

The workflow files are in `elixir/workflows/planning.md` and `elixir/workflows/development.md`. Both use Jira by default — swap the `tracker` block for Linear if needed (see the Linear example above).

---

## Running

Load your credentials and start Symphony with a workflow file:

```bash
source .env
./elixir/bin/symphony my-workflow.md --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

To run multiple repos in parallel, open one terminal per workflow file:

```bash
# Terminal 1 — backend
source .env && ./elixir/bin/symphony elixir/workflows/api.md --i-understand-that-this-will-be-running-without-the-usual-guardrails

# Terminal 2 — frontend
source .env && ./elixir/bin/symphony elixir/workflows/frontend.md --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

### Optional flags

```bash
# Enable the web dashboard at http://localhost:4000
./elixir/bin/symphony my-workflow.md --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 4000

# Write logs to a custom directory
./elixir/bin/symphony my-workflow.md --i-understand-that-this-will-be-running-without-the-usual-guardrails --logs-root ~/logs/symphony
```

---

## Front matter reference

| Field | Default | Description |
|-------|---------|-------------|
| `tracker.kind` | — | `jira` or `linear` |
| `tracker.active_states` | tracker-specific | Ticket states that trigger agent dispatch |
| `tracker.terminal_states` | tracker-specific | Ticket states that stop the agent |
| `tracker.assignee` | — | Optional — limit to one assignee (email or account ID) |
| `polling.interval_ms` | `30000` | How often to poll the tracker |
| `workspace.root` | system tmp | Directory where workspaces are created |
| `hooks.after_create` | — | Shell script run after workspace is created (clone repo here) |
| `hooks.before_remove` | — | Shell script run before workspace is deleted |
| `agent.max_concurrent_agents` | `10` | Max parallel agents for this workflow |
| `agent.max_turns` | `20` | Max agent turns per ticket attempt |
| `codex.command` | `codex app-server` | Command used to launch the agent |
| `codex.approval_policy` | `reject` | `never` to run fully unattended |

---

## License

[Apache License 2.0](LICENSE)
