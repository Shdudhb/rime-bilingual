# Agent Instructions

## 遵守 ~\.codex\AGENTS.md

## Project
This project adds bilingual English annotations to
Rime/Weasel Pinyin candidates on Windows.

## Source of truth
- Product requirements: SPEC.md
- Architecture: docs/ARCHITECTURE.md

## Development rules
- Do not modify upstream Weasel source unless SPEC.md requires it.
- Prefer Rime Lua extensions for the MVP.
- Translation requests must never block the input method UI.
- Local dictionary/cache must be checked before network APIs.
- Preserve existing Rime candidate ordering and selection behavior.
- Do not send password-field content to external translation APIs.

## Validation
Before considering a task complete:
- Verify normal Pinyin input still works.
- Verify candidate selection still works.
- Test both horizontal and vertical candidate layouts.
- Run relevant automated tests.