# Symphony — Harumi Setup

Symphony polls Jira for tickets and runs autonomous coding agents against your repositories. Each agent gets an isolated workspace, clones the target repo, and works the ticket end-to-end.

## How it works

1. Symphony polls Jira for tickets in the configured active states.
2. For each eligible ticket, it creates an isolated workspace directory.
3. It clones the target repository into that workspace (`hooks.after_create`).
4. It launches a Claude agent inside the workspace with the ticket context as the prompt.
5. The agent works until the ticket reaches a terminal state or the turn limit is reached.
6. When a ticket moves to a terminal state, Symphony stops the agent and cleans up.

There is one Symphony instance per repository. Harumi runs four:

| Instance | Repository | Workflow file |
|----------|-----------|---------------|
| Frontend | `harumi-io/frontend` | `elixir/workflows/frontend.md` |
| API | `harumi-io/harumi-api` | `elixir/workflows/api.md` |
| AI Solver | `harumi-io/ai-solver` | `elixir/workflows/ai.md` |
| Infrastructure | `harumi-io/infrastructure` | `elixir/workflows/infrastructure.md` |

---

## Prerequisites

### 1. Elixir runtime

Install [mise](https://mise.jdx.dev/) to manage the Elixir/Erlang versions:

```bash
brew install mise
```

Then inside this repo:

```bash
cd elixir
mise trust
mise install
```

### 2. Claude CLI

Install and authenticate [Claude Code](https://claude.ai/code):

```bash
npm install -g @anthropic-ai/claude-code
claude login
```

### 3. GitHub CLI

Required for the agent to open PRs and interact with GitHub:

```bash
brew install gh
gh auth login
```

---

## Configuration

### Jira credentials

Copy `.env.example` to `.env` at the root of this repo and fill in your values:

```bash
cp .env.example .env
```

```env
JIRA_API_TOKEN=your-jira-api-token
JIRA_EMAIL=you@harumi.io
JIRA_SITE_URL=https://your-org.atlassian.net
JIRA_PROJECT_KEY=KAN
```

**How to get a Jira API token:**

1. Go to [https://id.atlassian.com/manage-profile/security/api-tokens](https://id.atlassian.com/manage-profile/security/api-tokens)
2. Click **Create API token**
3. Give it a name (e.g. `symphony`) and copy the token

> The `.env` file is gitignored and never committed.

### Optional: limit to your own tickets

To make a Symphony instance only pick up tickets assigned to you, add `assignee` to the workflow file's front matter:

```yaml
tracker:
  assignee: "you@harumi.io"   # or your Jira accountId
```

---

## Build

Build the Symphony binary once (or after pulling changes):

```bash
cd elixir
mise exec -- mix setup
mise exec -- mix build
```

This produces `elixir/bin/symphony`.

---

## Running

Load your credentials and start the instance for the repository you want to run:

```bash
source .env

# Frontend
./elixir/bin/symphony elixir/workflows/frontend.md --i-understand-that-this-will-be-running-without-the-usual-guardrails

# API
./elixir/bin/symphony elixir/workflows/api.md --i-understand-that-this-will-be-running-without-the-usual-guardrails

# AI Solver
./elixir/bin/symphony elixir/workflows/ai.md --i-understand-that-this-will-be-running-without-the-usual-guardrails

# Infrastructure
./elixir/bin/symphony elixir/workflows/infrastructure.md --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

To run multiple instances at the same time, open one terminal per repository.

### Optional flags

```bash
# Enable the web dashboard at http://localhost:4000
./elixir/bin/symphony elixir/workflows/api.md --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 4000

# Write logs to a custom directory
./elixir/bin/symphony elixir/workflows/api.md --i-understand-that-this-will-be-running-without-the-usual-guardrails --logs-root ~/logs/symphony-api
```

---

## Jira board setup

Symphony expects the following statuses on the KAN board. Tickets in `active_states` are eligible for dispatch; tickets in `terminal_states` are ignored.

| Status | Role |
|--------|------|
| `To Do` | Queued — agent will pick up and move to `In Progress` |
| `In Progress` | Agent is actively working |
| `Doing` | Also treated as active (same as In Progress) |
| `UNDER REVIEW` | PR submitted — waiting for human review |
| `Done` | Terminal — agent will not touch |
| `Backlog` | Terminal — agent will not touch |

To route a ticket to a specific repository, use a Jira label matching the instance name (`frontend`, `api`, `ai`, `infrastructure`) and start only the corresponding Symphony instance. Without a label filter, any running instance will pick up any eligible ticket.

---

## Workspaces

Each instance stores its workspaces in a separate directory under `~/code/symphony-workspaces/`:

| Instance | Workspace root |
|----------|---------------|
| Frontend | `~/code/symphony-workspaces/frontend` |
| API | `~/code/symphony-workspaces/api` |
| AI Solver | `~/code/symphony-workspaces/ai` |
| Infrastructure | `~/code/symphony-workspaces/infrastructure` |

Workspaces persist across runs. A workspace for a ticket is reused on retry so the agent can continue from where it left off.

---

## Workflow files

Each workflow file (`elixir/workflows/*.md`) has two parts:

- **YAML front matter** — tracker config, polling interval, workspace root, hooks, agent limits, and Claude settings.
- **Markdown body** — the prompt template sent to the agent, with access to `{{ issue.identifier }}`, `{{ issue.title }}`, `{{ issue.state }}`, `{{ issue.description }}`, and `{{ issue.labels }}`.

To customize behavior for a repository, edit its workflow file. Changes are picked up on the next polling cycle without restarting Symphony.

---

## License

[Apache License 2.0](LICENSE)
