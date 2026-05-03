# Decisions Log

Chronological log of design decisions made during implementation. All agents should read this file at session start and append to it when making decisions that affect other modules.

---

## 2026-05-03 — Use a single shared DECISIONS.md for cross-agent communication
**Context:** Agents working in parallel need a way to communicate decisions without real-time coordination.
**Decision:** A single chronological `DECISIONS.md` in the repo root. Agents read it before starting work and append when they make decisions that affect other modules.
**Affects:** All agents / workflow.
