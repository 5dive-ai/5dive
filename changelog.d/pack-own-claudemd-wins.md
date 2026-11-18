## Unreleased — fix(import): an imported or shared agent keeps its pack's own CLAUDE.md

`agent import` re-rendered the agent's instructions from the pack's `persona.yaml` whenever the pack carried one, so a pack that also carried its own CLAUDE.md (a partner pack, a share, an export) lost every rule that text kept. A pack's CLAUDE.md now wins: it is installed as a catalogue hire is (the pack text, then the card, then the seat's own blocks), and `persona.yaml` renders the instructions only for a pack that has none. The persona is still installed for the card, the voice and the portrait.

`agent export` (and so `agent share`) now carries only the agent's own section of CLAUDE.md, not the blocks every seat starts with, so a re-import does not install them twice. A pack exported whole before this is trimmed the same way on import.
