@AGENTS.md

## Claude Code
- This repo ships its own `skills/review-nvim/SKILL.md` (with a `main.py` that mirrors
  `storage.lua`'s `SCHEMA_SQL`) — prefer invoking that skill over ad-hoc DuckDB queries when a task
  touches comment storage/schema.

- Never run destructive commands (force-push, hard reset, branch deletion, production
  deploys) without explicit human confirmation.
- Do NOT commit secrets, credentials, or PII.
