---
name: context-repair
description: Diagnose why a session went wrong and repair the context layer that caused it — CLAUDE.md, AGENTS.md, docs/BALLIQ_SPEC.md, the memory directory, .claude/skills, or .claude/agents briefs. Use when the user corrects a wrong assumption you stated confidently, when a documented fact turns out to be stale or missing, when a subagent reports its brief didn't match the code, at the end of a session that took avoidable wrong turns, or when asked to "fix the harness" / "why did you think that".
---

# Context repair

Adapted from *Trace: TRajectory Attribution for Automated Context Engineering* (Amazon,
[arXiv:2608.09153](https://arxiv.org/abs/2608.09153)). Premise: when an agent fails in a
deployment like this one, the defect is almost never in the model — it's in the context
sources the model was handed. Those sources are files in this repo, so they are repairable
in the same session that exposed them. Numbers quoted below are the paper's, measured on 60
synthetic dissatisfaction traces; treat them as direction, not as guarantees.

The failure mode this exists to prevent: fixing the *task* and leaving the *context* broken,
so the next session makes the identical mistake.

## 0. The context surface you are allowed to repair

| Layer | Files | Typical fault |
|---|---|---|
| System prompt | `CLAUDE.md` | a standing instruction that was never written down |
| Skills / process | `AGENTS.md`, `.claude/skills/*/SKILL.md` | a procedure that no longer matches reality |
| Knowledge base | `docs/BALLIQ_SPEC.md`, `docs/*.md`, `~/.claude/projects/-Users-xanderevans-Documents-fantasy-app/memory/*.md` | a fact that was true and isn't |
| Tool prompts | `.claude/agents/*.md`, `.claude/settings.local.json`, `.claude/launch.json` | a command, flag, or contract quoted wrong |
| Retrieval index | `MEMORY.md` hook lines, every skill's `description:` field | correct content that never gets found |

Out of scope: the user's global `/Users/xanderevans/CLAUDE.md` (it governs other projects
too — surface the problem, don't edit it), and anything under `.git/`.

## 1. Detect — the signal is usually implicit

You will rarely be told "your context is wrong." Watch for these instead:

**Explicit (act on one):** the user states you're wrong about a fact; a tool call fails
because a documented command/flag/path doesn't exist; a subagent reports its brief didn't
match the code; a test contradicts a documented behavior.

**Implicit (act on two, or one plus a wasted step):** the user rephrases the same request
after your answer; the user re-states a constraint they already gave; you had to grep for
something the docs should have told you; you asserted something confidently and then found
the opposite in the code; you re-derived a fact that turns out to be in memory already.

A correction lands on the task. The defect lives in the context. Those are different repairs
and you owe both.

## 2. Attribute — one backward pass over the whole session

Do **not** walk the session step by step asking "did this step contain the error." Every step
downstream of a bad fact contains the error; only one *introduced* it. The paper measured
per-step iteration at half the accuracy of a single holistic pass, at 16× the cost.

Instead, in one pass:

1. **Write the delta.** Literally: "Expected X, got Y." This is the loss signal; everything
   else is guided by it.
2. **Read the session in reverse temporal order** — final answer → tool outputs → your own
   reasoning → the original request.
3. **Find the earliest point that is inconsistent with the delta**, not the latest. Later
   steps merely propagated it.
4. **Use your own stated reasoning as the evidence trail.** Wherever you wrote "per CLAUDE.md",
   "the spec says", "memory says", or "the brief pasted" — that sentence names the context
   file to suspect. That is the highest-signal artifact in the whole trace.
5. **Output:** the root-cause step, the specific file (and line/section), and one fault
   category from the taxonomy below.

Expect to be right about three-quarters of the time on the exact node, and to have the true
cause in your top three nearly always. So carry a second and third candidate into step 3
rather than committing to one.

## 3. Verify before you write — reading decides CREATE vs UPDATE, inference does not

Attribution is a **hypothesis**, not a conclusion. Before writing anything:

1. **Read the implicated file.** Not the part you remember — open it.
2. **Search for a sibling that already covers it.** `grep -ril "<topic>"` across the memory
   directory, `docs/`, and `AGENTS.md`. A near-duplicate memory is worse than no memory.
3. **Cross-reference the authoritative source** — live Supabase, the ASC API, the actual
   Swift/Python code, `git log` — per AGENTS.md §1. A doc is not authority for its own
   correctness.
4. **Check the neighbors.** Whatever went stale rarely went stale alone (AGENTS.md §2). If
   `schema.sql` drifted, check the indexes too; if a build number is stale, check release
   status in the same section.

This step is not optional overhead — it is the single highest-leverage part of the loop.
Deciding CREATE-vs-UPDATE from the file itself scored 83% in the paper versus 33% when
inferred without reading, and exploration *overturned* the upstream attribution 67% of the
time it was wrong. If what you read contradicts step 2, believe the file and re-attribute.

## 4. Write the smallest correct CRUD operation

| Category | Operation | Target |
|---|---|---|
| Fact was true, now false | **UPDATE in place** | edit the wrong claim; never append a contradiction beside it |
| Fact never recorded | **CREATE** | one new memory file (one fact per file) or one spec line |
| Procedure no longer matches | **UPDATE** | the `AGENTS.md` rule or `SKILL.md` step |
| Content exists but wasn't found | **UPDATE the index** | the `MEMORY.md` hook line or the skill's `description:` — add the words a future session would actually search for. Don't duplicate the content. |
| Claim is simply wrong and unrecoverable | **DELETE** | remove it; a deleted memory beats a misleading one |
| Signal is a one-off preference, not a defect | **NO_ACTION** | say so and stop |

Constraints: a new `AGENTS.md` rule must cite the concrete incident that produced it — that's
the file's whole format, and an ungrounded rule is noise. Never rewrite a doc wholesale to fix
one line. When a live change and a file disagree, fix both in the same commit (CLAUDE.md's
`schema.sql` rule generalized).

## 5. Report

State: the delta, the root-cause file and section, the fault category, the operation you
performed, and what you *verified* versus what you assumed. Per AGENTS.md §9, quantify —
"grepped the memory dir, 0 existing files covered this, created one" beats "updated memory."

## Fault taxonomy for this repo

Six categories, each with a real instance from this repo's history:

1. **PROCESS_STALE** — a documented procedure that no longer holds. *The `supabase` CLI is
   logged into a different account than this project; the documented path had to move to the
   MCP tools.*
2. **KB_STALE** — a recorded fact that has since changed. *Build/release status in
   BALLIQ_SPEC §8 goes stale every submission.*
3. **KB_GAP** — the fact was never recorded, so there's nothing to update. *That an inactive
   Paid Apps Agreement returns an empty product fetch everywhere — invisible in code, and
   nothing in the repo said it.*
4. **TOOL_PROMPT_ERROR** — a command, flag, contract, or subagent brief quoted wrong. *A
   subagent handed an RPC signature that didn't match the deployed function.*
5. **SYSTEM_PROMPT_GAP** — a standing instruction the user holds but CLAUDE.md doesn't state.
   *"Execute DB functions directly, don't ask" — re-authorized every session until written down.*
6. **RETRIEVAL_FAILURE** — correct content that never surfaced. *Two Supabase decoders exist
   and picking the wrong one silently returns `[]`; the knowledge existed but wasn't indexed
   under words anyone would search.*

## What not to do

- Don't repair context for a one-off preference, a taste call, or a mistake with no
  documentary cause. Not every failure is a context failure — some are just bugs.
- Don't add a rule that isn't grounded in something that actually happened.
- Don't let this loop expand the session's scope. It is a diagnosis and a small write,
  not a documentation project.
