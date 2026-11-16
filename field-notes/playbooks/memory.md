# Memory that keeps its oldest facts

An agent loads a memory index every session.
When the index grows past the load limit, the oldest facts drop off with no error.

## How it runs

1. Keep one fact per file.
2. Keep the always-loaded file short: a router that says how to search.
The facts live in their own files.
3. Find facts in two steps: search, then open only the files you picked.
4. Rebuild the router on a schedule. One cleanup grew back within hours.

One agent's index went from 43,462 bytes to 4,804 bytes this way. No fact was deleted.
