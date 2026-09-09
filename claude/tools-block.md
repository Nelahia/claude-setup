## CLI tooling (managed by Nelahia/claude-setup)

- Bash output passes through RTK before you read it: compressed, grouped, sometimes truncated.
  When a result looks incomplete or contradicts what you expect, re-run it as `rtk proxy <cmd>`
  to see the raw output before drawing a conclusion.
- `Read`, `Grep` and `Glob` bypass RTK entirely — their output is unfiltered.
- Response tone comes from the active output style, not from instructions restated per prompt.
