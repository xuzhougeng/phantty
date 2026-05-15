# Agent Skill Tool Design

## Goal

Add an MVP skill system for AI/Agent chats that supports explicit `$skill_name`
invocation and slash-command discovery while preserving DeepSeek prefix-cache
stability.

The design must not dynamically rewrite system prompts, tool schemas, or prior
conversation history when skills are added or edited. Skill hot reload should
only affect future skill tool calls.

## Ghostty Reference

Ghostty does not have an AI chat, agent tool loop, slash-command surface, or
skill system. This feature is Phantty-specific and should follow the existing
`src/ai_chat.zig` agent tool-call architecture and `src/agent_history.zig`
persistence model instead of a Ghostty implementation.

## User Model

- `$skill_name <task>` explicitly loads a skill for the next agent turn.
- `/skills` lists available skills locally and does not enter LLM history.
- `/commands` lists slash commands locally and does not enter LLM history.
- `/reload-skills` rescans the skill directory locally and does not enter LLM
  history.

Viewing commands and skill metadata is local UI behavior. Only task execution
creates conversation history.

## DeepSeek Cache Constraints

Keep these surfaces stable across app restarts and skill hot reloads:

- system prompt text
- OpenAI-compatible tool schema
- persisted prior messages
- historical tool results

Do not inject the current skill list into the system prompt or tool schema.

The fixed tool surface should be stable:

- `skill_info`
- later: `skill_resource`
- later: `skill_run`

The MVP should implement `skill_info` first. `skill_resource` and `skill_run`
can be added after the registry and transcript model are correct.

## Skill Directory

Default skill root:

```text
skills/
  my-skill/
    SKILL.md
    references/
    scripts/
```

MVP parsing only requires YAML frontmatter fields:

- `name`
- `description`

The skill body is the content after the frontmatter. Unknown frontmatter fields
should be ignored for forward compatibility.

Skill lookup should allow directory name and frontmatter `name`. Duplicate names
should return a deterministic error listing the conflicting directories.

## Runtime Flow

### Slash Commands

Slash commands are handled before normal submit:

1. Trim input.
2. If it starts with `/`, handle locally.
3. Append a local assistant/tool-style informational card if useful, but do not
   append a `user` message and do not call the LLM.
4. Do not persist slash command output as conversation history unless the user
   explicitly starts a task.

### `$skill_name`

When the submitted prompt begins with `$` followed by a skill token:

1. Parse `skill_name` and the remaining user task.
2. Add the user task to history without the `$skill_name` prefix, or with a
   short stable marker such as `Using skill: skill_name`.
3. Preload the skill by executing the same code path as the `skill_info` tool.
4. Include the loaded skill as a tool result in the request transcript before
   asking the model to answer the task.
5. Persist the exact loaded skill snapshot with the conversation.

Hot reload affects step 3 only for future submissions. Existing persisted skill
snapshots must be replayed exactly as saved.

## Transcript Persistence Requirement

Current `src/ai_chat.zig` stores UI messages with roles `user`, `assistant`,
and `tool`, but `Session.buildRequestLocked()` skips `tool` messages when
creating API request messages. That is acceptable for transient progress cards,
but not for skill snapshots that must remain part of later model context.

Implementation must add a durable distinction between:

- UI progress messages that should not be replayed to the model.
- API transcript tool messages that must be replayed exactly.

The minimum safe approach is to extend stored messages with optional API tool
metadata:

- `tool_call_id`
- `tool_name`
- `replay_to_model`

Then `buildRequestLocked()` should include only tool messages where
`replay_to_model` is true. Historical tool result content must come from
`agent-history.json`, not from the current filesystem.

## Tool Result Format

`skill_info` should return a deterministic text snapshot:

```text
# Skill: <name>
source: <relative skill directory>
hash: <content hash>

<SKILL.md body or full content>
```

The hash is informational and helps users/debugging identify whether a future
skill reload changed content. It is not used to mutate old messages.

Errors should also be deterministic:

- skill not found
- invalid `SKILL.md`
- duplicate skill name
- skill file too large

## Scope

In scope for MVP:

- skill registry scanning
- `SKILL.md` frontmatter parsing
- `/skills`
- `/commands`
- `/reload-skills`
- `$skill_name` explicit invocation
- stable `skill_info` tool schema
- durable replay of skill tool snapshots
- tests for parsing, slash behavior, and history round-trip

Out of scope for MVP:

- semantic skill search
- automatic skill selection without `$skill_name`
- script execution from skills
- reference file loading
- automatic skill creation or task-end skill promotion
- TypeScript/OpenClaw/MCP plugin bridge

## Test Plan

- Unit-test skill registry parsing for valid frontmatter, missing frontmatter,
  duplicate names, and hot reload after file changes.
- Unit-test `$skill_name` parsing and ensure slash commands do not append user
  history.
- Unit-test `Session` history round-trip preserves replayable tool messages.
- Unit-test request JSON includes replayable skill tool messages and excludes
  non-replayable progress tool cards.
- Build with `zig build`.

