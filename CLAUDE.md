# Notes for coding agents

## Read first

**`docs/development.md`** — commands, hard constraints, the invariants the tests enforce,
design principles and conventions. Then `docs/taxonomy.md` (the product) and
`docs/decisions.md` (why things are the way they are).

There is no plan or roadmap file, by design. Open checks live in `development.md`
(*Verifying in Lightroom*, *Planned*, *Not built*); the user chooses the next work each session.

Do not re-litigate the design principles in `development.md`. Change one only on new
evidence, and record the change as a new ADR in `docs/decisions.md`, rewriting any ADR it
replaces so the record stays consistent.

## The short version of the hard constraints

- Lightroom embeds **Lua 5.1.4**: `unpack`, no `goto`, no `\u{}` escapes, no `//`.
- SDK namespaces via `import 'LrX'`; `require` is for plugin files only.
- Anything that yields — including **every catalog read** — uses `LrTasks.pcall`, never a
  plain `pcall` (it fails silently in Lightroom).
- Every async task registers `context:addFailureHandler`.
- `get/setPropertyForPlugin` take `_PLUGIN`. No `os.getenv` or `os.remove` (use `LrFileUtils`).
- No external runtime; the only process launched is the bundled model runtime
  (`model/localgenres`) through `GrCli.lua`, data in temp files, never on the command line.
- The model's genres are fixed: read them from `GrTaxonomy`; `make model FROM=<folder>`
  imports a new model (`KEYWORDS=<folder>` adds the keyword model, ADR-030). Keyword names
  come from `GrKeywordTaxonomy`, never from code. Never commit label files (`*labels*.json`).
- Docs describe the model — how it was trained, its accuracy, its assumptions and limits — but
  never name or refer to the separate project that produces it.
- Plugin Lua files are flat in the bundle root with a `Gr` prefix.
- A new `.lua` file means restarting Lightroom.
- **Never hard-code a genre name**; read `GrTaxonomy.genres`.

## Commands

```bash
make test      # offline suite; no Lightroom, no network
make lint      # byte-compile under LuaJIT
```

If a change makes an invariant test fail (table in `docs/development.md`), the change is
wrong unless the requirement was explicitly revised.
