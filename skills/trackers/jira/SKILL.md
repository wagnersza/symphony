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
