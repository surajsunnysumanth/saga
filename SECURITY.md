# Security

## Private reporting

Do not report vulnerabilities through public issues, discussions or pull requests, and do not attach real archives, message text, contact details or keys.

**Pre-launch blocker:** the owner has not yet designated a verified private vulnerability-reporting channel or security contact. Public launch is gated on establishing and testing one, then replacing this paragraph with exact instructions. No email address, reporting URL, response deadline or supported-release policy is implied by this draft. Until a private route is confirmed, keep details private rather than posting them publicly.

A useful private report contains the affected revision, operating-system/toolchain versions, the security boundary affected, reproduction steps using synthetic data, and expected versus actual results. Include only the minimum necessary evidence. Report suspected data exposure without sending the exposed data itself.

## Threat model

Saga reads highly sensitive personal archives. Its local vault and derived databases are not a secure messaging service and do not preserve WhatsApp's end-to-end encryption after import.

| Boundary | Intended protection and limits |
| --- | --- |
| Source backup to importer | Source backups should be read-only; importing requires access to the backup and, where applicable, its key. Treat both as secrets. |
| Vault and caches on disk | Vault segments/configuration and index/AI/metadata caches contain sensitive plaintext unless optional vault encryption is enabled. Encryption is off by default and covers `segments/` and `config/*.json` only; the derived SQLite index, AI cache and link-metadata cache remain plaintext. Protect the Mac and backup destination with encryption and access controls. |
| Other local processes | Keychain storage protects the saved Android backup key, not an unlocked vault, copied key files or exported data. Saga does not protect against malware or another process with access to your files. |
| Local AI | Built-in providers use Apple on-device models or local Ollama/LM Studio HTTP endpoints. The local server and its configuration are part of your trust boundary. Model answers can be wrong; check citations. |
| Media links and players | Remote providers receive requests for previews, artwork or playback. Title/artwork lookups are off by default and require enabling a toggle; embedded players, opened links and cached-artwork thumbnails can still contact providers when used. See [PRIVACY.md](PRIVACY.md). Third-party players are not offline content. |
| MCP client | The server is local/read-only, but returns private archive content to its client. The client may send it to a remote model. Read-only is not a confidentiality boundary. Use only trusted clients and inspect their settings. |
| Cloud-mounted folders | Reading online-only media may trigger a provider download; putting a vault in a synced folder lets that provider store it. Saga does not control the provider's account, encryption or retention policies. |
| Exports and screenshots | Exported chats, Wrapped pages/PDFs and screenshots may reveal message text, names and relationships. Anyone receiving them can copy them further. |

No telemetry or analytics feature is intended. This is not a certification, penetration-test report, guarantee against data loss, or claim that all network paths have been dynamically audited. See [PRIVACY.md](PRIVACY.md) for the reviewed data flows and [CONTRIBUTING.md](CONTRIBUTING.md) for how to report a problem without exposing private data.

## Contributor requirements

Use synthetic fixtures. Never paste real exploit data into a public report. Keep untrusted archive text escaped in rendered output, enforce read-only access where promised, and test changes to file paths, SQL tools, subprocess execution, media rendering and model prompts. Preserve source backups and avoid destructive migration without verification and an undo path.
