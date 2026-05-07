# Tracker Skills + Claude Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the planning and development workflows the agent-side capability to read attachments (incl. images), edit comments, upload attachments, edit summary/description, and create subtasks against Jira and Linear — across both Claude and Codex agent runtimes.

**Architecture:** A canonical `skills/` directory at the repo root holds every Symphony skill. Tracker skills (`jira`, `linear`) carry parallel "via Claude (curl)" and "via Codex (tool)" recipe sections. Both `.claude/skills` and `.codex/skills` are whole-directory symlinks into `skills/`. A new `.claude-plugin/` declares a Claude Code plugin scoped to **only** the tracker subset (`skills/trackers/`) so symphony-internal flow skills (`commit`, `debug`, `land`, `pull`, `push`) stay out of the public plugin. No Elixir code changes.

**Tech Stack:** Markdown skills, JSON plugin manifests, filesystem symlinks, curl, Jira REST v3, Linear GraphQL.

---

## Notes for the executing engineer

- **Where to run things:** plan tasks happen at the repo root (`/Users/wagner.souza/git/symphony`), not inside `elixir/`.
- **No Elixir test impact.** This plan moves Markdown files, creates new ones, and adds two `.json` files plus two symlinks. Running `cd elixir && mix test` after every task is **not** required and would waste cycles. Verification is `git status`, file existence, and `readlink`.
- **Symlinks are committed.** Git stores them as a special object containing the target path. `git mv` does not preserve the move-as-rename when the target type changes; we explicitly `git rm` the directory and create a symlink in its place.
- **Existing references stay valid.** `elixir/workflows/api.md` and `frontend.md` reference `.codex/skills/land/SKILL.md`. After the move + symlink, that path still resolves (the symlink redirects). No edits needed in those files.
- **Public plugin scope is `skills/trackers/`.** Anything outside that subfolder is invisible to the Claude plugin, even though it lives under `skills/`.
- **Commit message convention:** the repo uses Conventional Commits (`feat:`, `refactor:`, `docs:`, `chore:`). Commit after each task. Single-author footer: `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>`.
- **Don't push during execution.** Final push is one operation at the end (or by the user).

---

## File map (what each task produces)

**New canonical skills home:**
- `skills/trackers/jira/SKILL.md` — NEW
- `skills/trackers/linear/SKILL.md` — moved from `.codex/skills/linear/SKILL.md`, refreshed with curl recipes
- `skills/commit/SKILL.md` — moved from `.codex/skills/commit/SKILL.md`
- `skills/debug/SKILL.md` — moved from `.codex/skills/debug/SKILL.md`
- `skills/land/SKILL.md`, `skills/land/land_watch.py` — moved from `.codex/skills/land/`
- `skills/pull/SKILL.md` — moved from `.codex/skills/pull/SKILL.md`
- `skills/push/SKILL.md` — moved from `.codex/skills/push/SKILL.md`

**Symlinks:**
- `.claude/skills` → `../skills` (NEW symlink, replaces nothing — `.claude/` is also new)
- `.codex/skills` → `../skills` (NEW symlink, replaces the existing real `.codex/skills/` directory)

**Plugin manifest:**
- `.claude-plugin/plugin.json` — NEW
- `.claude-plugin/marketplace.json` — NEW

**Workflow file edits (small):**
- `elixir/workflows/planning.md` — add tracker-skills reference
- `elixir/workflows/development.md` — add tracker-skills reference
- `README.md` — document plugin install + Codex `cp -r skills/ workspace/.codex/skills/` recipe

**Verification only — no edits expected, but symlink resolution must be confirmed:**
- `elixir/workflows/api.md`
- `elixir/workflows/frontend.md`

---

## Task 1: Move existing `.codex/skills/` contents to `skills/`

Pure file move. No content change. Symphony's existing flow skills (`commit`, `debug`, `land`, `pull`, `push`) move out of the codex-specific path and into the canonical home. Linear's skill moves into the trackers subfolder.

**Files:**
- Create: `skills/commit/SKILL.md` (from `.codex/skills/commit/SKILL.md`)
- Create: `skills/debug/SKILL.md` (from `.codex/skills/debug/SKILL.md`)
- Create: `skills/land/SKILL.md` (from `.codex/skills/land/SKILL.md`)
- Create: `skills/land/land_watch.py` (from `.codex/skills/land/land_watch.py`)
- Create: `skills/pull/SKILL.md` (from `.codex/skills/pull/SKILL.md`)
- Create: `skills/push/SKILL.md` (from `.codex/skills/push/SKILL.md`)
- Create: `skills/trackers/linear/SKILL.md` (from `.codex/skills/linear/SKILL.md`)
- Delete: `.codex/skills/` (entire directory)

- [ ] **Step 1: Create the new directory tree**

```bash
mkdir -p skills/trackers
```

- [ ] **Step 2: Move every existing skill via `git mv`**

```bash
git mv .codex/skills/commit skills/commit
git mv .codex/skills/debug skills/debug
git mv .codex/skills/land skills/land
git mv .codex/skills/pull skills/pull
git mv .codex/skills/push skills/push
git mv .codex/skills/linear skills/trackers/linear
```

- [ ] **Step 3: Verify the directory is now empty and remove it**

Run:
```bash
ls -la .codex/skills/ 2>/dev/null
```
Expected: `total 0` / nothing left.

Then:
```bash
rmdir .codex/skills
```

- [ ] **Step 4: Verify everything moved**

Run:
```bash
ls skills/ skills/trackers/
```
Expected:
```
skills/:
commit  debug  land  pull  push  trackers
skills/trackers/:
linear
```

- [ ] **Step 5: Commit**

```bash
git add skills/ .codex/
git commit -m "$(cat <<'EOF'
refactor: move skills to canonical skills/ home

Move .codex/skills/{commit,debug,land,pull,push} to skills/<name>/ and
.codex/skills/linear to skills/trackers/linear. Establishes a single
canonical skills root that both .claude/ and .codex/ will symlink to in
a follow-up commit.

No skill content is modified in this commit.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Symlink `.codex/skills/` → `../skills/`

Restores the path that `elixir/workflows/api.md`, `frontend.md`, and the existing land flow reference (`.codex/skills/land/SKILL.md`) — without duplicating content.

**Files:**
- Create symlink: `.codex/skills` → `../skills`

- [ ] **Step 1: Create the symlink**

```bash
ln -s ../skills .codex/skills
```

- [ ] **Step 2: Verify it's a symlink with the right target**

Run:
```bash
readlink .codex/skills
```
Expected: `../skills`

- [ ] **Step 3: Verify path resolution still works**

Run:
```bash
ls .codex/skills/land/SKILL.md .codex/skills/trackers/linear/SKILL.md
```
Expected: both files listed (resolved through the symlink).

- [ ] **Step 4: Verify `git ls-files -s .codex/skills` reports a symlink**

Run:
```bash
git add .codex/skills
git ls-files -s .codex/skills
```
Expected: a single line starting with `120000` (symlink mode), e.g.:
```
120000 <hash> 0  .codex/skills
```
If you see `100644` or `040000`, the symlink wasn't created correctly — abort and redo Step 1.

- [ ] **Step 5: Commit**

```bash
git commit -m "$(cat <<'EOF'
refactor: symlink .codex/skills to ../skills

Restore the .codex/skills/* paths that existing workflow files
(api.md, frontend.md, the land flow) reference, now resolving into the
canonical skills/ tree.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Symlink `.claude/skills/` → `../skills/`

Mirrors the codex symlink so a workspace cloned and run through Claude Code's local-plugin path resolves the same skills.

**Files:**
- Create directory: `.claude/`
- Create symlink: `.claude/skills` → `../skills`

- [ ] **Step 1: Create the `.claude/` directory and the symlink**

```bash
mkdir -p .claude
ln -s ../skills .claude/skills
```

- [ ] **Step 2: Verify**

Run:
```bash
readlink .claude/skills
ls .claude/skills/trackers/linear/SKILL.md
```
Expected: `../skills` and the file resolves.

- [ ] **Step 3: Commit**

```bash
git add .claude/
git commit -m "$(cat <<'EOF'
chore: add .claude/skills symlink to canonical skills/

Mirrors .codex/skills so local-development Claude sessions resolve the
same skill set.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Author `skills/trackers/jira/SKILL.md`

The agent-facing reference for Jira REST v3. Two parallel sections: "via Claude (curl)" — what every workflow run today uses — and "via Codex (`jira_rest` tool)" — a stub noting the Codex dynamic tool is not yet implemented and to fall back to bash. Recipes cover every operation `planning.md` and `development.md` rely on.

**Files:**
- Create: `skills/trackers/jira/SKILL.md`

- [ ] **Step 1: Create the file with the required frontmatter and content**

Write `skills/trackers/jira/SKILL.md`:

````markdown
---
name: jira
description: |
  Jira Cloud REST v3 recipes for reading issues, comments, and attachments;
  creating and editing comments; uploading attachments; editing summary and
  description; creating subtasks; and listing/executing transitions.
  Use when the active workflow tracker is Jira.
---

# Jira

Use this skill for every Jira REST v3 operation a workflow needs. Pick the
section that matches your agent runtime: **Claude → curl**, **Codex → `jira_rest`
tool (not yet available — fall back to curl)**.

## Auth

The orchestrator passes these env vars into your shell:

- `$JIRA_SITE_URL` — e.g. `https://your-org.atlassian.net`
- `$JIRA_EMAIL`
- `$JIRA_API_TOKEN`

Every curl call below uses `-u "$JIRA_EMAIL:$JIRA_API_TOKEN"`. Do not echo
these values back into Jira comments, descriptions, or PR bodies.

Common headers:

```
-H "Accept: application/json"
-H "Content-Type: application/json"
```

For attachment uploads add `-H "X-Atlassian-Token: no-check"` (Atlassian's
CSRF-bypass header for multipart uploads).

## Comment body limit

Jira Cloud caps a single comment body at **32,767 characters**. Keep payloads
≤ 30,000 to leave headroom. If your spec or plan exceeds this, attach a file
(see "Upload an attachment" below) and post a short pointer comment.

## Description format (ADF)

Jira's `description` and comment `body` fields use Atlassian Document Format
(ADF), not raw markdown. The minimal wrapper for plain text is:

```json
{
  "type": "doc",
  "version": 1,
  "content": [
    { "type": "paragraph", "content": [{ "type": "text", "text": "<your body>" }] }
  ]
}
```

For multi-paragraph or richer content, repeat `paragraph` blocks. ADF supports
`bulletList`, `orderedList`, `codeBlock`, `heading`, etc. — keep it simple
unless the workflow specifies otherwise.

---

## Via Claude (curl)

### Read an issue with comments and attachment list

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -H "Accept: application/json" \
  "$JIRA_SITE_URL/rest/api/3/issue/PROJ-123?expand=renderedFields,changelog&fields=summary,description,status,labels,attachment,issuelinks"
```

To list comments separately (paginated):

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -H "Accept: application/json" \
  "$JIRA_SITE_URL/rest/api/3/issue/PROJ-123/comment?startAt=0&maxResults=100"
```

### Download an attachment (including images for vision)

The `attachment` array on an issue returns objects with a `content` URL. To save
locally and let Claude's vision read it:

```bash
ATTACHMENT_URL="<copy from issue.fields.attachment[i].content>"
mkdir -p .symphony-attachments
curl -sSL -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -o .symphony-attachments/mockup.png \
  "$ATTACHMENT_URL"
```

Then `Read` the local path (`.symphony-attachments/mockup.png`); Claude's
native vision will parse it. Treat any image attachment as a first-class
requirement source alongside the description text.

### Create a comment

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X POST \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -d '{
    "body": {
      "type": "doc",
      "version": 1,
      "content": [
        { "type": "paragraph", "content": [{ "type": "text", "text": "Your comment here" }] }
      ]
    }
  }' \
  "$JIRA_SITE_URL/rest/api/3/issue/PROJ-123/comment"
```

The response body includes the new `id`. Persist it if you'll edit the comment
later (revision flow).

### Edit an existing comment

Use the `id` from the create response (or the one returned by the comment list
endpoint):

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X PUT \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -d '{
    "body": {
      "type": "doc",
      "version": 1,
      "content": [
        { "type": "paragraph", "content": [{ "type": "text", "text": "Updated body" }] }
      ]
    }
  }' \
  "$JIRA_SITE_URL/rest/api/3/issue/PROJ-123/comment/$COMMENT_ID"
```

### Upload an attachment

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X POST \
  -H "X-Atlassian-Token: no-check" \
  -F "file=@spec-and-plan.md" \
  "$JIRA_SITE_URL/rest/api/3/issue/PROJ-123/attachments"
```

Response is an array of attachment objects. Each has a `content` URL you can
download from later.

To replace an existing attachment with the same filename, first delete the old
one:

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -X DELETE \
  "$JIRA_SITE_URL/rest/api/3/attachment/$OLD_ATTACHMENT_ID"
```

Then upload the new copy.

### Edit summary and/or description

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X PUT \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -d '{
    "fields": {
      "summary": "New concise summary",
      "description": {
        "type": "doc",
        "version": 1,
        "content": [
          { "type": "paragraph", "content": [{ "type": "text", "text": "New stable problem statement." }] }
        ]
      }
    }
  }' \
  "$JIRA_SITE_URL/rest/api/3/issue/PROJ-123"
```

Send only the fields you want to change. The Description is for the durable
problem statement — never put progress notes there.

### List available transitions and execute one

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -H "Accept: application/json" \
  "$JIRA_SITE_URL/rest/api/3/issue/PROJ-123/transitions"
```

The response has `transitions[].id` and `transitions[].to.name`. Execute by id:

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X POST \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -d '{ "transition": { "id": "<transition-id>" } }' \
  "$JIRA_SITE_URL/rest/api/3/issue/PROJ-123/transitions"
```

### Discover the project's subtask issuetype id

You only need this once per project (the id is stable). Cache the result for
the rest of the workflow run.

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -H "Accept: application/json" \
  "$JIRA_SITE_URL/rest/api/3/issue/createmeta?projectKeys=$JIRA_PROJECT_KEY&issuetypeNames=Subtask&expand=projects.issuetypes"
```

Pull `projects[0].issuetypes[?name=='Subtask'].id`. If your project uses a
different name (e.g. `Sub-task`), adjust the query.

### Create a subtask under a parent

```bash
curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  -X POST \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -d '{
    "fields": {
      "project":   { "key": "'"$JIRA_PROJECT_KEY"'" },
      "parent":    { "key": "PROJ-123" },
      "summary":   "Task 1: short title from plan",
      "issuetype": { "id": "<subtask-issuetype-id>" },
      "description": {
        "type": "doc",
        "version": 1,
        "content": [
          { "type": "paragraph", "content": [{ "type": "text", "text": "Acceptance: ...\nVerify: ...\nFiles: ...\nDepends on: ...\nSize: M" }] }
        ]
      }
    }
  }' \
  "$JIRA_SITE_URL/rest/api/3/issue"
```

Response includes the new subtask `key` (e.g. `PROJ-456`). After all subtasks
are created, post a comment on the parent listing the mapping (Task N → key).

---

## Via Codex (`jira_rest` tool)

A native Codex dynamic tool for Jira REST is **not yet implemented** in
Symphony. Codex sessions targeting Jira should fall back to the curl recipes
above using the standard shell tool. The Linear adapter has a parallel
`linear_graphql` dynamic tool — see `skills/trackers/linear/SKILL.md` for the
Codex pattern that will eventually be mirrored here.

---

## Usage rules

- Always check that `$JIRA_API_TOKEN`, `$JIRA_EMAIL`, and `$JIRA_SITE_URL` are
  non-empty before any call. If any is missing, post a blocker comment on the
  ticket and stop.
- Persist comment ids and attachment ids you'll need later (e.g. for the
  revision-mode "edit existing comment" flow). Don't list comments twice.
- Never paste auth values into a comment body, attachment, or PR description.
- Prefer attaching a file over splitting a long body across multiple comments.
````

- [ ] **Step 2: Verify the file is well-formed**

Run:
```bash
head -10 skills/trackers/jira/SKILL.md
```
Expected: starts with `---` frontmatter, name and description present.

- [ ] **Step 3: Commit**

```bash
git add skills/trackers/jira/
git commit -m "$(cat <<'EOF'
docs: add Jira tracker skill for Claude/Codex workflow agents

Author skills/trackers/jira/SKILL.md with curl recipes for the full set of
operations the planning and development workflows rely on: read issue +
comments + attachments, download attachment (incl. images for vision),
create/edit comment, upload attachment, edit summary and description,
list/execute transitions, and create subtasks.

Codex section is currently a stub — Codex agents fall back to curl until
a jira_rest dynamic tool is implemented.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Refresh `skills/trackers/linear/SKILL.md` with curl recipes

The existing file documents only the `linear_graphql` Codex tool. Add a parallel "via Claude (curl)" section that covers the same Jira-equivalent operations against the Linear GraphQL API, so Claude-runtime workflows can target Linear with the same set of capabilities.

**Files:**
- Modify: `skills/trackers/linear/SKILL.md`

- [ ] **Step 1: Read the existing file**

```bash
cat skills/trackers/linear/SKILL.md
```

Note where the existing "Common workflows" section ends. The new section will
go below it, above the final "Usage rules" block.

- [ ] **Step 2: Add a "Via Claude (curl)" section before the "Usage rules" block**

Insert the following block immediately above `## Usage rules` (the existing
top-level heading near the bottom of the file):

````markdown
---

## Via Claude (curl)

The Codex `linear_graphql` tool is unavailable when the agent runtime is
`claude -p`. Use the Linear GraphQL endpoint over HTTPS directly.

### Auth

The orchestrator passes `$LINEAR_API_KEY` into your shell. Every call uses
the personal-API-key header:

```
Authorization: $LINEAR_API_KEY
Content-Type: application/json
```

> Linear's personal API keys are sent as the literal value of `Authorization`
> (no `Bearer` prefix). OAuth tokens differ; this skill assumes personal keys.

### Helper: a curl wrapper for one GraphQL call

```bash
linear_gql() {
  local query="$1"
  local variables="${2:-{}}"
  curl -s -X POST \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg q "$query" --argjson v "$variables" '{query:$q, variables:$v}')" \
    "https://api.linear.app/graphql"
}
```

Use `jq` to read responses:

```bash
linear_gql 'query($id:String!){ issue(id:$id){ id identifier title } }' \
  '{"id":"PROJ-123"}' | jq .
```

### Read an issue with comments and attachments

```graphql
query IssueWithContext($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
    description
    state { id name type }
    comments(first: 50) { nodes { id body createdAt user { name } } }
    attachments { nodes { id title url sourceType } }
  }
}
```

For image attachments, follow the URL with curl and the Linear API key in the
Authorization header. Save the file locally, then `Read` its path so Claude's
vision parses it.

### Create / edit a comment

```graphql
mutation CreateComment($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) {
    success
    comment { id }
  }
}
```

```graphql
mutation UpdateComment($id: String!, $body: String!) {
  commentUpdate(id: $id, input: { body: $body }) {
    success
    comment { id }
  }
}
```

### Edit summary (title) and description

```graphql
mutation UpdateIssue($id: String!, $title: String, $description: String) {
  issueUpdate(id: $id, input: { title: $title, description: $description }) {
    success
    issue { id title }
  }
}
```

Pass only the fields you want to change.

### List team workflow states and move an issue

```graphql
query TeamStates($id: String!) {
  issue(id: $id) {
    team {
      states { nodes { id name type } }
    }
  }
}
```

```graphql
mutation MoveIssue($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
    issue { id state { id name } }
  }
}
```

### Create a subtask under a parent

Linear models subtasks as issues with a `parentId`. Look up the parent's
`teamId` first:

```graphql
query Parent($id: String!) {
  issue(id: $id) { id team { id } }
}
```

Then create the child:

```graphql
mutation CreateSubtask(
  $teamId: String!,
  $parentId: String!,
  $title: String!,
  $description: String,
  $stateId: String
) {
  issueCreate(input: {
    teamId: $teamId,
    parentId: $parentId,
    title: $title,
    description: $description,
    stateId: $stateId
  }) {
    success
    issue { id identifier }
  }
}
```

### Upload an attachment (3-step Linear upload)

1. **Request a signed upload URL.**

   ```graphql
   mutation FileUpload($filename: String!, $contentType: String!, $size: Int!) {
     fileUpload(filename: $filename, contentType: $contentType, size: $size) {
       success
       uploadFile {
         uploadUrl
         assetUrl
         headers { key value }
       }
     }
   }
   ```

2. **PUT the bytes to `uploadUrl`** with the headers from the response. The
   signed URL already authorizes the upload — do not add `$LINEAR_API_KEY`.

   ```bash
   curl -s -X PUT \
     -H "Content-Type: text/markdown" \
     --data-binary @spec-and-plan.md \
     "$UPLOAD_URL"
   ```

3. **Reference `assetUrl`** in a comment body or via `attachmentLinkURL` if you
   want a first-class attachment record on the issue.

### Linear comment body sizing

Linear comment bodies accept long markdown without a hard 32k cap, but
keep individual comments scannable. If a body would be larger than ~15k
characters, attach a file (3-step flow above) and link it from a short pointer
comment — same posture as the Jira flow.
````

- [ ] **Step 3: Verify the file still has well-formed frontmatter and structure**

Run:
```bash
head -8 skills/trackers/linear/SKILL.md
grep -c "^## " skills/trackers/linear/SKILL.md
```
Expected: frontmatter intact; total `## ` headings increased by ~10 vs. before.

- [ ] **Step 4: Commit**

```bash
git add skills/trackers/linear/SKILL.md
git commit -m "$(cat <<'EOF'
docs: add Linear curl recipes for Claude-runtime workflows

The existing skill documents only the Codex linear_graphql tool. Add a
parallel "Via Claude (curl)" section covering issue read, comment
create/edit, summary/description edit, state move, subtask create, and the
3-step file upload flow — matching the Jira skill's surface area so
workflow files can be tracker-agnostic.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Add the Claude Code plugin manifest

Declares the Claude plugin scoped to `skills/trackers/` only. Mega-plugin is
explicitly avoided — symphony-internal flow skills (`commit`, `debug`, `land`,
`pull`, `push`) stay invisible to plugin consumers.

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`

- [ ] **Step 1: Create `.claude-plugin/plugin.json`**

Write `.claude-plugin/plugin.json`:

```json
{
  "name": "symphony-trackers",
  "description": "Tracker recipes (Jira, Linear) for Symphony agents — comments, attachments, subtasks, transitions.",
  "version": "0.1.0",
  "author": {
    "name": "Symphony"
  },
  "homepage": "https://github.com/wagnersza/symphony",
  "repository": "https://github.com/wagnersza/symphony",
  "license": "Apache-2.0",
  "skills": "./skills/trackers"
}
```

- [ ] **Step 2: Create `.claude-plugin/marketplace.json`**

Write `.claude-plugin/marketplace.json`:

```json
{
  "name": "symphony",
  "owner": {
    "name": "Symphony"
  },
  "metadata": {
    "description": "Symphony's Claude Code plugin marketplace."
  },
  "plugins": [
    {
      "name": "symphony-trackers",
      "source": {
        "source": "github",
        "repo": "wagnersza/symphony"
      },
      "description": "Tracker recipes (Jira, Linear) for Symphony agents."
    }
  ]
}
```

- [ ] **Step 3: Validate JSON**

Run:
```bash
python3 -m json.tool .claude-plugin/plugin.json > /dev/null
python3 -m json.tool .claude-plugin/marketplace.json > /dev/null
```
Expected: both commands exit 0, no output.

- [ ] **Step 4: Confirm `skills/trackers/` is what the plugin will publish**

Run:
```bash
ls skills/trackers/
```
Expected: `jira  linear` (and nothing else — no `commit`, `debug`, etc.).

If you see anything beyond `jira` and `linear`, the plugin would publish more
than intended. Stop and verify Task 1 moved non-tracker skills to the top
level (`skills/<name>/`), not into `skills/trackers/`.

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/
git commit -m "$(cat <<'EOF'
feat: add Claude Code plugin manifest for symphony-trackers

Declares a plugin scoped to skills/trackers/ only — Jira and Linear
recipes — so the public plugin surface stays narrow. Symphony-internal
flow skills (commit, debug, land, pull, push) remain in skills/<name>/
and are not exposed by the plugin.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Reference the tracker skills from the planning + development workflows

Add a short pointer in each workflow file so the agent loads the relevant
tracker skill at the start of every run.

**Files:**
- Modify: `elixir/workflows/planning.md`
- Modify: `elixir/workflows/development.md`

- [ ] **Step 1: Add a "Tracker operations" block to `planning.md`**

In `elixir/workflows/planning.md`, immediately after the existing
`**Prerequisite:** This workflow requires the [agent-skills]...` block (the one
that ends with `/plugin install agent-skills@addy-agent-skills`), add:

```markdown
**Tracker skills:** This workflow expects either:
- the Symphony plugin installed in Claude Code (`/plugin install symphony-trackers@symphony`), **or**
- the workspace `after_create` hook to copy the repo's `skills/` tree into
  `.codex/skills/` for Codex sessions (`cp -r path/to/symphony/skills .codex/skills`).

For every Jira/Linear API call, follow the appropriate tracker skill:

- Jira: `skills/trackers/jira/SKILL.md`
- Linear: `skills/trackers/linear/SKILL.md`

Pick the section that matches your runtime (Claude → curl, Codex → tool).
```

- [ ] **Step 2: Add the same block to `development.md`**

Apply the identical insertion in `elixir/workflows/development.md`, after the
matching `**Prerequisite:**` block.

- [ ] **Step 3: Verify the workflow files still parse**

Run a basic markdown sanity check:
```bash
head -60 elixir/workflows/planning.md | grep -E "^(##|---|tracker:|active_states:)" | head -10
head -60 elixir/workflows/development.md | grep -E "^(##|---|tracker:|active_states:)" | head -10
```
Expected: front matter (`---`, `tracker:`, `active_states:`) and headings appear in the right order — the new block did not displace the YAML front matter.

- [ ] **Step 4: Commit**

```bash
git add elixir/workflows/planning.md elixir/workflows/development.md
git commit -m "$(cat <<'EOF'
docs: point planning + development workflows at tracker skills

Both workflows now reference skills/trackers/{jira,linear}/SKILL.md for
the API recipes they rely on (comment edit, attachment up/download,
summary/description edit, subtask create), and document the two install
paths: Claude plugin (symphony-trackers) for Claude runtime; copy
skills/ into .codex/skills/ via after_create hook for Codex runtime.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Update README with install paths

Document for users: Claude install (one-line plugin command) and Codex install
(`cp -r` line for the workflow's `after_create` hook).

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Find the existing agent-skills install section**

Run:
```bash
grep -n "Installing agent-skills\|/plugin install" README.md
```
Note the line numbers — the new section goes adjacent to it.

- [ ] **Step 2: Add a "Symphony tracker plugin" subsection**

In `README.md`, immediately after the existing "Installing agent-skills" block
(the one with `/plugin marketplace add addyosmani/agent-skills`), insert:

````markdown
### Installing the Symphony tracker plugin

Symphony ships its own Claude Code plugin with the Jira and Linear API
recipes that the planning and development workflows depend on
(`skills/trackers/jira/SKILL.md`, `skills/trackers/linear/SKILL.md`).

```
/plugin marketplace add wagnersza/symphony
/plugin install symphony-trackers@symphony
```

> If you don't have GitHub SSH keys configured, use the HTTPS URL:
> ```
> /plugin marketplace add https://github.com/wagnersza/symphony.git
> /plugin install symphony-trackers@symphony
> ```

### Codex runtime — staging skills into the workspace

If your workflow uses Codex (`codex.command: codex app-server`) instead of
Claude, the plugin install above does not apply. Stage the skills directly
into the workspace via the workflow's `after_create` hook:

```yaml
hooks:
  after_create: |
    git clone --depth 1 https://github.com/your-org/your-repo .
    # ...other setup...
    cp -r /path/to/symphony/skills .codex/skills
```

Replace `/path/to/symphony/` with the absolute path to your local Symphony
checkout. The workspace will resolve `.codex/skills/trackers/jira/SKILL.md`
the same way Claude resolves the plugin path.
````

- [ ] **Step 3: Verify the README still renders sensibly**

Run:
```bash
grep -nE "^##? " README.md | head -30
```
Expected: heading hierarchy intact, "Installing the Symphony tracker plugin"
appears as a subsection of the agent-skills section.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: document Symphony tracker plugin install paths

Add Claude Code plugin install instructions
(/plugin install symphony-trackers@symphony) and document the Codex-runtime
workspace-staging recipe (cp -r skills/ .codex/skills/) for users whose
workflows run Codex instead of Claude.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Final smoke check

End-to-end sanity that nothing broke and the structure matches intent. No code
change in this task; if anything fails, the relevant earlier task is the one
to fix.

- [ ] **Step 1: Symlinks resolve**

Run:
```bash
readlink .claude/skills .codex/skills
ls .claude/skills/trackers/jira/SKILL.md
ls .codex/skills/trackers/linear/SKILL.md
ls .codex/skills/land/SKILL.md
```
Expected: both symlinks point at `../skills`; all three files resolve.

- [ ] **Step 2: Existing workflow file references still work**

Run:
```bash
grep -l "\.codex/skills/land/SKILL.md" elixir/workflows/*.md
ls .codex/skills/land/SKILL.md
```
Expected: matches in `api.md` and `frontend.md`; the path resolves.

- [ ] **Step 3: Plugin scope is tracker-only**

Run:
```bash
ls skills/trackers/
```
Expected: `jira  linear` and nothing else.

- [ ] **Step 4: Plugin manifests are valid JSON**

Run:
```bash
python3 -m json.tool .claude-plugin/plugin.json > /dev/null && echo plugin.json OK
python3 -m json.tool .claude-plugin/marketplace.json > /dev/null && echo marketplace.json OK
```
Expected: both lines print `OK`.

- [ ] **Step 5: Existing Elixir code still compiles**

Run:
```bash
cd elixir && mise exec -- mix compile --warnings-as-errors
```
Expected: clean compile, no warnings. (No Elixir was edited; this is a
defense-in-depth check that the symlink restructure didn't accidentally affect
file globs the Elixir build relies on.)

- [ ] **Step 6: Existing tests still pass**

Run:
```bash
cd elixir && mise exec -- mix test
```
Expected: all green. Same rationale as Step 5.

- [ ] **Step 7: No commit needed**

This task is verification only. If everything passes, the plan is done. If
anything fails, fix the relevant prior task and re-run this smoke check.

---

## Out of scope (explicit non-goals)

The following were considered and deferred, with rationale:

- **Codex `jira_rest` dynamic tool.** Per brainstorming decision: ship Jira-via-curl-only for v1. The Jira skill includes a stub Codex section noting the fallback. A future plan can mirror the existing `Codex.DynamicTool.linear_graphql` shape (`elixir/lib/symphony_elixir/codex/dynamic_tool.ex`) for Jira REST when Codex usage on Jira accounts becomes meaningful.
- **`bin/install-codex-skills.sh` helper.** Per brainstorming decision: a plain `cp -r` line in the workflow's `after_create` hook is enough; a script wrapper is YAGNI.
- **`Tracker` behaviour additions** (e.g. `create_subtask`, `upload_attachment`). The orchestrator does not need to call these. Adding them would force Linear/Memory adapters to grow stubs. The agent does these calls itself via the skills.
- **`PromptBuilder` edits.** No new template variables are required; the workflow file edits in Task 7 are pure prose.
- **Linear plugin install.** The plugin already ships the Linear skill alongside Jira. Workflows that want only Linear use the same plugin.
