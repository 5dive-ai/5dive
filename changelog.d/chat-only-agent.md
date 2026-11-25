## Unreleased — feat(agent): a chat-only agent that someone outside the team can type into — `5dive agent create <name> --chat-only`

`sudo 5dive agent create <name> --type=claude --channels=dashboard --chat-only` makes an agent for a web chat that people outside your team can use. It starts with no tools: no built-ins (`--tools ""`, and each one also denied by name), no skills, no slash commands, and a permission mode that refuses anything except the chat's reply tool. Its replies are text only, with no files and no voice (dashboard plugin 0.5.43 or later). Any other type or channel is refused at create time and again at start. Either the agent's `AGENT_CHAT_ONLY=1` stamp or a root-owned file `/etc/5dive/chat-only-agents/<name>` turns the mode on, and neither can turn it off.

`--stopped` creates any agent without enabling or starting its service, for agents that should run only when needed.
