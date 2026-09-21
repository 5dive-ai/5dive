# The UI contributor page moved

`5dive ui` is no longer part of this repository. It is a plugin with its own repo —
**[5dive-ai/5dive-ui](https://github.com/5dive-ai/5dive-ui)** — so that changing a screen means
cloning one file's worth of project instead of 121k lines of runtime. The contributor page that
was here, the screenshots and the scoped issues all live there now; install it with
`5dive plugin add 5dive-ai/5dive-ui` and `5dive ui` works exactly as it did. What stayed in core
is the *data*: [`5dive board`](board-contract.md) emits the versioned document the views render,
because the board is a fact about core's own data model and only core can say what is on it.
