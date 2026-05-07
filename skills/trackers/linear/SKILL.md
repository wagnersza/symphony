---
name: linear
description: |
  Use Symphony's `linear_graphql` client tool for raw Linear GraphQL
  operations such as comment editing and upload flows.
---

# Linear GraphQL

Use this skill for raw Linear GraphQL work during Symphony app-server sessions.

## Primary tool

Use the `linear_graphql` client tool exposed by Symphony's app-server session.
It reuses Symphony's configured Linear auth for the session.

Tool input:

```json
{
  "query": "query or mutation document",
  "variables": {
    "optional": "graphql variables object"
  }
}
```

Tool behavior:

- Send one GraphQL operation per tool call.
- Treat a top-level `errors` array as a failed GraphQL operation even if the
  tool call itself completed.
- Keep queries/mutations narrowly scoped; ask only for the fields you need.

## Discovering unfamiliar operations

When you need an unfamiliar mutation, input type, or object field, use targeted
introspection through `linear_graphql`.

List mutation names:

```graphql
query ListMutations {
  __type(name: "Mutation") {
    fields {
      name
    }
  }
}
```

Inspect a specific input object:

```graphql
query CommentCreateInputShape {
  __type(name: "CommentCreateInput") {
    inputFields {
      name
      type {
        kind
        name
        ofType {
          kind
          name
        }
      }
    }
  }
}
```

## Common workflows

### Query an issue by key, identifier, or id

Use these progressively:

- Start with `issue(id: $key)` when you have a ticket key such as `MT-686`.
- Fall back to `issues(filter: ...)` when you need identifier search semantics.
- Once you have the internal issue id, prefer `issue(id: $id)` for narrower reads.

Lookup by issue key:

```graphql
query IssueByKey($key: String!) {
  issue(id: $key) {
    id
    identifier
    title
    state {
      id
      name
      type
    }
    project {
      id
      name
    }
    branchName
    url
    description
    updatedAt
    links {
      nodes {
        id
        url
        title
      }
    }
  }
}
```

Lookup by identifier filter:

```graphql
query IssueByIdentifier($identifier: String!) {
  issues(filter: { identifier: { eq: $identifier } }, first: 1) {
    nodes {
      id
      identifier
      title
      state {
        id
        name
        type
      }
      project {
        id
        name
      }
      branchName
      url
      description
      updatedAt
    }
  }
}
```

Resolve a key to an internal id:

```graphql
query IssueByIdOrKey($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
  }
}
```

Read the issue once the internal id is known:

```graphql
query IssueDetails($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
    url
    description
    state {
      id
      name
      type
    }
    project {
      id
      name
    }
    attachments {
      nodes {
        id
        title
        url
        sourceType
      }
    }
  }
}
```

### Query team workflow states for an issue

Use this before changing issue state when you need the exact `stateId`:

```graphql
query IssueTeamStates($id: String!) {
  issue(id: $id) {
    id
    team {
      id
      key
      name
      states {
        nodes {
          id
          name
          type
        }
      }
    }
  }
}
```

### Edit an existing comment

Use `commentUpdate` through `linear_graphql`:

```graphql
mutation UpdateComment($id: String!, $body: String!) {
  commentUpdate(id: $id, input: { body: $body }) {
    success
    comment {
      id
      body
    }
  }
}
```

### Create a comment

Use `commentCreate` through `linear_graphql`:

```graphql
mutation CreateComment($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) {
    success
    comment {
      id
      url
    }
  }
}
```

### Move an issue to a different state

Use `issueUpdate` with the destination `stateId`:

```graphql
mutation MoveIssueToState($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
    issue {
      id
      identifier
      state {
        id
        name
      }
    }
  }
}
```

### Attach a GitHub PR to an issue

Use the GitHub-specific attachment mutation when linking a PR:

```graphql
mutation AttachGitHubPR($issueId: String!, $url: String!, $title: String) {
  attachmentLinkGitHubPR(
    issueId: $issueId
    url: $url
    title: $title
    linkKind: links
  ) {
    success
    attachment {
      id
      title
      url
    }
  }
}
```

If you only need a plain URL attachment and do not care about GitHub-specific
link metadata, use:

```graphql
mutation AttachURL($issueId: String!, $url: String!, $title: String) {
  attachmentLinkURL(issueId: $issueId, url: $url, title: $title) {
    success
    attachment {
      id
      title
      url
    }
  }
}
```

### Introspection patterns used during schema discovery

Use these when the exact field or mutation shape is unclear:

```graphql
query QueryFields {
  __type(name: "Query") {
    fields {
      name
    }
  }
}
```

```graphql
query IssueFieldArgs {
  __type(name: "Query") {
    fields {
      name
      args {
        name
        type {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
            }
          }
        }
      }
    }
  }
}
```

### Upload a video to a comment

Do this in three steps:

1. Call `linear_graphql` with `fileUpload` to get `uploadUrl`, `assetUrl`, and
   any required upload headers.
2. Upload the local file bytes to `uploadUrl` with `curl -X PUT` and the exact
   headers returned by `fileUpload`.
3. Call `linear_graphql` again with `commentCreate` (or `commentUpdate`) and
   include the resulting `assetUrl` in the comment body.

Useful mutations:

```graphql
mutation FileUpload(
  $filename: String!
  $contentType: String!
  $size: Int!
  $makePublic: Boolean
) {
  fileUpload(
    filename: $filename
    contentType: $contentType
    size: $size
    makePublic: $makePublic
  ) {
    success
    uploadFile {
      uploadUrl
      assetUrl
      headers {
        key
        value
      }
    }
  }
}
```

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

---

## Usage rules

- Use `linear_graphql` for comment edits, uploads, and ad-hoc Linear API
  queries.
- Prefer the narrowest issue lookup that matches what you already know:
  key -> identifier search -> internal id.
- For state transitions, fetch team states first and use the exact `stateId`
  instead of hardcoding names inside mutations.
- Prefer `attachmentLinkGitHubPR` over a generic URL attachment when linking a
  GitHub PR to a Linear issue.
- Do not introduce new raw-token shell helpers for GraphQL access.
- If you need shell work for uploads, only use it for signed upload URLs
  returned by `fileUpload`; those URLs already carry the needed authorization.
