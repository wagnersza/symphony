# symphony-claude-agent

Thin Node wrapper around the Claude Agent SDK used by Symphony's `:claude`
backend. Reads line-delimited JSON commands from stdin; writes line-delimited
JSON events to stdout.

## Install

```
cd elixir/priv/claude_agent
npm ci
```

## Requirements

- Node 20+
- Claude CLI logged in (`~/.claude/` populated). The SDK reuses those credentials.

## Protocol

See `docs/superpowers/specs/2026-05-07-claude-agent-backend-design.md`.
