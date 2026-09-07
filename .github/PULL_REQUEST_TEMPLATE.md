<!--
Title: `<type>: <what changed>` or `<area>: <what changed>` — e.g. `fix: duplicate SKU 500s`,
`console-ui: typed error handling, steps 1-2`. Imperative, no ticket prefix, no trailing period.

Label the PR before merge — `.github/release.yml` builds the changelog from labels, and an
unlabelled PR lands in ":question: Other Changes":
  type/enhancement · type/bug · type/documentation · type/test · type/chore · type/dependency-upgrade
  warn/api-change · warn/behavior-change · warn/deprecation · warn/regression · warn/blocker
  ignore-changelog

Branch cut from an up-to-date `origin/main` in its own worktree, merged into `main` by PR. Never push to `main`.
-->

## Why

<!-- The problem, in the reader's terms. What breaks, what is missing, what it costs today.
     Link the issue/plan (`.claude/plans/<name>.md`) if there is one. One paragraph is usually enough. -->

## What

<!-- The change, at the level of decisions rather than a file list — the diff already lists files.
     If it is a multi-step plan, say which steps this PR is and what is deliberately not wired yet. -->

## The parts that are not obvious

<!-- Optional but the most valuable section. Traps, orderings, and things a reviewer would
     otherwise have to re-derive: why this layer, why this fails closed, what the alternative cost.
     Delete the heading if the change genuinely has none. -->

## Deviations

<!-- Optional. Where this departs from the plan, the issue, or the neighbouring pattern — and why.
     "Not done" belongs here too, named explicitly rather than left for the reviewer to notice. -->

## Verification

<!-- What you actually ran, with the result. Not "tested locally".
     Baseline honesty: if a suite was already failing, say so with the before/after counts. -->

- [ ] `scripts/verify.sh` green for the exact tree being pushed (fmt, init + validate per root and module, tflint, catalog drift, cfn-lint)
- [ ] `plan (dev)` on this PR read and sane — the resources it adds, changes and destroys are the ones intended
- [ ] `qa/platform-qa.md` updated for what changed, with each new case tagged `[verified]` / `[not verified]`
- [ ] A catalog change has its `../cvhome` counterpart on a branch of the same name (the drift check compares by name)

