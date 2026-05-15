# Skill loading eval suite

Fixed filesystem fixtures for Phantty's explicit skill loader. This suite does
not call an LLM: `$skill` routing is deterministic, so the regression target is
whether `SKILL.md` files are discovered, matched by name or directory, and
rendered into stable replayable snapshots.

## Run

```powershell
zig build test
```

The Zig test `skill_registry eval: fixture skills load expected snapshots`
loads `tests/eval/skill-load-cases.json` and reads skills from
`tests/eval/skills`.

## Case schema

```json
{
  "name": "human-readable case name",
  "skill": "requested skill name or directory",
  "expected_name": "resolved frontmatter name, or null for no match",
  "expected_source": "expected source directory",
  "expected_contains": "substring expected in the rendered snapshot",
  "tags": ["optional", "not consumed"],
  "notes": "optional rationale"
}
```

`expected_name: null` means the loader should return `SkillNotFound`.

## Adding cases

1. Add a fixture under `tests/eval/skills/<dir>/SKILL.md`.
2. Add one or more cases to `skill-load-cases.json`.
3. Include both name and directory alias cases when frontmatter `name` differs
   from the directory.
4. Keep at least one no-match case to guard against over-matching.

## Cache stability

The loader renders a deterministic snapshot:

```text
# Skill: <name>
source: <source>
hash: <hash>

<raw SKILL.md>
```

Conversation history stores this snapshot as a replayable tool result. Changing
the file later should only affect future explicit loads, not historical tool
results.
