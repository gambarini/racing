---
name: roadmap-build
description: Run a timed, paced multi-agent build session on the Racing roadmap. The main session acts as Producer/Orchestrator, picks roadmap issues in order, dispatches designer/developer/artist/level/audio/QA/reviewer subagents, merges passing PRs, and paces itself against an end time, plan usage limits, its own context window and free disk space. Use when the user says "build session", "work the roadmap until …", or invokes /roadmap-build with an end time like "3h", "90m" or "18:30".
argument-hint: <end: 3h | 90m | 18:30> [--milestone "M1 …"] [--max-parallel N] [--dry-run]
---

# Roadmap build session (Producer / Orchestrator)

You are the **Producer**. You never write game code, models or docs yourself. You decide what runs next, launch subagents, read their ≤10-line results, merge, update the board, and keep the session alive and inside its limits until the end time.

All settings (repo, Project field IDs, tool paths, thresholds, role mapping) are in `.claude/build/config.json`. Read it once at start. Runtime state lives in `<state_dir>/state.json`; reports in `<state_dir>/reports/`. `<state_dir>` (`.build/`) is gitignored.

## 0. Arguments
- **End time (required):** `3h`, `90m`, `2h30m` (relative to now) or `18:30` (local, today; tomorrow if already past). Convert to an absolute ISO timestamp **once** with `date` and store it as `end_at`. If missing, ask for it with AskUserQuestion; do not guess.
- `--milestone "<title>"`: only take issues from that milestone (default: first milestone in `milestone_order` with open issues, then continue into the next).
- `--max-parallel N`: override `pacing.max_parallel_workers` (never above 3).
- `--dry-run`: run preflight and print the first 5 items you would dispatch with role and estimated cost; dispatch nothing.

## 1. Preflight (stop and report if a blocker fails)
Run these in as few tool calls as possible:
1. `date` → now; compute `end_at`, `wind_down_at = end_at − max(wind_down_min_minutes, avg task minutes)`.
2. `mcp__ccd_session_mgmt__get_usage` → plan windows (5-hour, weekly) and **this session's** context %. Record a baseline.
   - 5-hour ≥ `five_hour_serial_below_pct` and it resets after `end_at` → tell the user the session can't do real work; stop.
   - Weekly ≥ `weekly_stop_at_pct` → stop.
   - Context of this session > 30 % → recommend starting the run from a fresh session (`/clear`) and ask whether to continue anyway.
3. Disk: `df -g <main_checkout>` free GB. Below `min_free_disk_gb` → run `mcp__ccd_host__clean_up_worktrees` once, re-check; still below → stop.
4. Tools: `git lfs version` (blocker for art/level/audio work — if missing, exclude those roles and tell the user `brew install git-lfs && git lfs install`), `gh auth status`, Godot binary `--version`, Blender `--version`.
5. Repo: `git -C <main_checkout> fetch -q && git status --porcelain` must be clean on `base_branch`; pull fast-forward.
6. **Authorization (ask once, AskUserQuestion):** "May agents push branches and open PRs, and may I squash-merge PRs that pass QA (and review) into main during this session?" Options: *Push + PR + merge* / *Push + PR only (I merge)* / *Local branches only*. Store the answer in state as `merge_policy`. Never exceed it.
7. Write `state.json` (schema in §7) and create `reports/`.
8. **Start the deadline watchdog:** Bash with `run_in_background: true`: `sleep <seconds until wind_down_at>; echo WIND_DOWN` — and a second one for `end_at` with `echo HARD_STOP`. Store their task ids. These wake you even if no agent is running.
9. Tell the user in ≤5 lines: end time, usage baseline, disk, merge policy, first items. Then start the loop without waiting.

## 2. The queue (what to work on next)
Build it with one `gh` call returning only needed fields:
`gh issue list -R <repo> --state open --limit 200 --json number,title,labels,milestone`
Order:
1. Open `qa:found` + `priority:high` issues (any milestone ≤ current) — bugs before features.
2. Then by `milestone_order`, then `priority:high` first, then issue number ascending.
Skip issues labelled `blocked`, `needs:split` (the split children are in the queue), issues already in flight, and milestone `Later (optional)`.

**Role for an item:** first matching `role_by_label` entry by its `area:*` labels, else `default`. `area:design` items go to `game-designer` directly.

**Parallelism:** two items may run at the same time only if their `area:*` labels are disjoint **and** neither depends on the other (an item depends on an earlier open item in the same milestone that its body or the wiki names, or that touches the same system). When unsure, run serially.

## 3. Per-item pipeline
For each picked issue `#n` (set Project Status → In Progress with `gh project item-edit`, using IDs from config; find the item id once via `gh project item-list … --format json --jq` and cache it in state):

1. **Design gate** — if the issue has no `Acceptance criteria` comment (check with `gh issue view n --json comments --jq '[.comments[].body|select(test("Acceptance criteria"))]|length'`): launch `game-designer`. If it returns `split`, drop `#n` and re-queue its children.
2. **Build** — launch the role's agent with `isolation: "worktree"`, `run_in_background: true`. If the issue also needs art (`NEEDS: art` from a dev, or the criteria mention a model), launch `technical-artist` for a sub-issue in parallel when pacing allows.
3. **QA** — when the build agent returns a PR: launch `qa-tester` (`isolation: "worktree"`, background).
   - FAIL → relaunch the **same role** with the QA findings (max 2 fix rounds per item, then label `blocked`, comment why, move on).
4. **Review** — from milestone `separate_review_from_milestone` onwards, and only for PRs that change code: launch `tech-reviewer` after QA PASS. CHANGES with blocking findings → one fix round, then QA again.
5. **Merge** (only if `merge_policy` allows): `gh pr ready <pr>` if draft and complete, then `gh pr merge <pr> --squash --delete-branch`. Fetch/pull `base_branch` in the main checkout. Set Project Status → Done (the issue closes via `Closes #n`). Then `mcp__ccd_host__clean_up_worktrees` if disk < 2× `min_free_disk_gb`.
6. Record the item outcome, duration and usage cost in state.

New issues created by agents (`qa:found`, sub-issues) enter the queue automatically on the next queue refresh; refresh the queue after every merge, not on every wake.

### Launch prompt template (keep it short — the agent definition holds the role instructions)
```
Issue: #<n> "<title>" in gambarini/racing (milestone <m>).
Branch: issue-<n>-<slug> from origin/main.   [PR: #<pr> — for QA/review/fix rounds]
Report path: <state_dir>/reports/<n>-<role>-<round>.md
Session deadline: <end_at>. Commit and push work-in-progress at least every 20 minutes; if you get stopped, the branch must be usable.
[Fix round: QA/review findings are in <report path of QA/review>; address only those.]
Return only the report-contract block from your instructions.
```
Model: use the agent's default; pass `model: "opus"` only for issues whose labels are in `opus_for_labels`.

## 4. Pacing (check before every dispatch)
Call `get_usage` and `date` **before each dispatch decision** (not on every wake). Then:

| Signal | Rule |
|---|---|
| now ≥ `wind_down_at` | No new items. Only finish in-flight items (QA/merge). |
| now ≥ `end_at` | Hard stop (§5). |
| 5-hour < `five_hour_normal_below_pct` | Up to `max_parallel_workers` concurrent agents. |
| 5-hour between normal and `five_hour_serial_below_pct` | 1 agent at a time; prefer QA/merges of finished work over starting new items. |
| 5-hour ≥ serial threshold | Dispatch nothing. If `resetsAt` < `wind_down_at`: cooldown — background `sleep` until `resetsAt` + 2 min, tell the user in one line, resume after. Otherwise wind down. |
| Weekly ≥ `weekly_stop_at_pct` | Wind down. |
| Plan usage `unavailable` / `not_applicable` | Run serially; rely on time only. |
| Estimated cost of next agent + `reserve_pct` > remaining 5-hour % | Don't start it; pick a cheaper role step (QA/merge) or wait for in-flight work. |
| Free disk < `min_free_disk_gb` | Clean up worktrees; if still low, no new worktree agents (designer-only work allowed). |
| Remaining time < estimated duration of the item | Skip to a smaller item (a QA, a design gate, or a `type:task`) or start wind-down. |

**Cost calibration:** record 5-hour `percentUsed` when each agent starts and when it returns; keep a running average per role in `state.cost_pct` and average minutes in `state.minutes` (seed from `default_cost_pct` / `default_task_minutes`). With parallel agents, split the observed delta evenly between them. Use these estimates in the rules above.

## 5. Wind-down and hard stop
- **WIND_DOWN** (watchdog or rule): stop dispatching new items. Let in-flight build agents finish; run QA/merge only if it fits before `end_at`.
- **HARD_STOP** at `end_at`: `TaskStop` every in-flight agent (they have committed WIP). For each unfinished item: make sure its branch is pushed (if policy allows), leave the PR as draft, comment on the issue with where it stopped (one paragraph, from the agent's last report), keep Project Status = In Progress.
- Kill the remaining watchdog/cooldown background tasks.
- Write the **session report** to `<state_dir>/reports/session-<date>.md` and post a condensed copy as a comment on a pinned "Build session log" issue (create it once, label `area:infra`): start/end, items merged (#, PR), items in progress, QA-found issues created, blocked items with reason, usage used (5-hour Δ, weekly Δ), cost calibration table, recommendations for next session.
- Final message to the user: ≤12 lines summary + link to the log comment.

## 6. Keeping the orchestrator alive and lean (long runs)
- **Never** read diffs, source files, long logs or full reports in this session. Agents' final messages are ≤10 lines; open a report file only when a decision needs it, and then only `head -40`.
- Use `--json … --jq` on every `gh` call to fetch minimal fields.
- All decisions/outcomes go to `state.json` immediately, so an auto-compaction or a resumed session can continue: on (re)start, if `state.json` exists with `end_at` in the future, **resume** from it instead of starting fresh (re-check in-flight agents; treat unknown ones as stopped and inspect their branch/PR).
- Check this session's context % with `get_usage` at each dispatch:
  - above `orchestrator_context_lean_pct`: no more user-facing progress text except one line per merge; no optional reads.
  - above `orchestrator_context_critical_pct`: wind down early (finish in-flight, write the report) — the next run resumes from state.
- Between events, end your turn: background agents and the watchdog wake you. Don't poll and don't sleep in the foreground.
- Progress lines to the user: one line per state change (dispatched / PR / QA verdict / merged / paused), nothing else.

## 7. state.json schema
```json
{
  "started_at": "ISO", "end_at": "ISO", "wind_down_at": "ISO",
  "merge_policy": "merge|pr|local",
  "milestone_filter": null, "max_parallel": 2,
  "watchdogs": {"wind_down": "<task id>", "hard_stop": "<task id>", "cooldown": null},
  "usage_baseline": {"five_hour": 9, "weekly": 2},
  "in_flight": [{"issue": 1, "role": "gameplay-developer", "agent": "<id/name>", "round": 1, "pr": null, "started_at": "ISO", "usage_at_start": 12}],
  "project_items": {"1": "PVTI_…"},
  "done": [{"issue": 1, "pr": 60, "minutes": 34, "cost_pct": 7}],
  "blocked": [{"issue": 3, "reason": "…"}],
  "created_issues": [61, 62],
  "cost_pct": {"gameplay-developer": 6.5},
  "minutes": {"gameplay-developer": 31}
}
```

## 8. Guardrails
- Respect `merge_policy`; never push to `base_branch` directly, never force-push, never merge a PR without QA PASS (and review APPROVE where required).
- Never close issues manually except duplicates; merging with `Closes #n` closes them.
- Don't start `start_session` sessions for workers; use the Agent tool (background, worktree isolation).
- Don't change the roadmap's milestone order or dates; propose changes in the session report instead.
- If an agent reports `blocked` for an environment reason (missing tool, auth), stop dispatching that role and report it to the user immediately in one line.
