# Saga MCP server

`saga-mcp` lets Claude Code, Claude Desktop or any MCP client query your WhatsApp archive. It is **read-only**, runs **locally over stdio** (no network, no account), and reads the library Saga already built (`vault_index.db`).

## Connect

Claude Code:
```
claude mcp add saga -- /Applications/Saga.app/Contents/MacOS/saga-mcp
```
(or Saga ▸ Go ▸ *Copy Claude Code connect command*). Claude Desktop: add to `claude_desktop_config.json`:
```json
{ "mcpServers": { "saga": { "command": "/Applications/Saga.app/Contents/MacOS/saga-mcp" } } }
```
Options: `--index <path>` (default `~/Library/Application Support/Saga/vault_index.db`), `--config <mcp.json>`.

## Tools
| tool | what for |
|---|---|
| `list_chats`, `list_people` | find chats / people, with counts and date ranges |
| `read_conversation` | transcript of one chat, by id or name, with date range |
| `search_messages`, `message_context` | full-text search (FTS5), then open the surrounding messages |
| `person_profile` | first/last message, yearly activity, shared groups |
| `activity` | counts by year / month / weekday / hour, for all, a chat or a person |
| `year_in_review` | Wrapped-style stats |
| `deleted_messages` | messages deleted on the phone but kept in your archive |
| `archive_stats`, `get_schema`, `sql_query` | overview; read-only SELECT for anything else |

Prompts: `catch_me_up`, `relationship_timeline`, `find_the_plan`.

Try: "Which year did Shagun and I talk most, and what changed?", "When did we agree the Goa dates?", "Who do I reply to slowest?" (via `sql_query`).

## Privacy
Tool results are sent to whichever model your MCP client uses (for Claude Code, Anthropic's API). That is your messages, and your contacts' messages. Be deliberate:
- `--config mcp.json`: `{"blocked_chats": ["Family", "12036302@g.us"], "max_results": 100, "allow_sql": false}`. Blocked chats are hidden from every tool. Configuring a block list turns `sql_query` off, because raw SQL could bypass it. Aggregates (`archive_stats`, `activity` totals) are filtered, but `year_in_review`/`person_profile` totals may still count blocked chats.
- Output is capped (~60k characters) so one question can't dump the archive.
- The database is opened read-only; nothing can be modified through the server.
- For fully local analysis, use a local MCP client with an on-device model.
