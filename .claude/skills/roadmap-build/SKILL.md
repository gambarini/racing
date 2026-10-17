---
name: roadmap-build
description: Run a timed, paced multi-agent build session on the Racing roadmap. The main session acts as Producer/Orchestrator, picks roadmap issues in order, dispatches designer/developer/artist/level/audio/QA/reviewer subagents, merges passing PRs, and paces itself against an end time, plan usage limits, its own context window and free disk space. Use when the user says "build session", "work the roadmap until …", or invokes /roadmap-build with an end time like "3h", "90m" or "18:30".
argument-hint: <end: 3h | 90m | 18:30> [--milestone "M1 …"] [--max-parallel N] [--dry-run]
---

# Roadmap build session (Producer / Orchestrator)

You are the **Producer**. You never write game code, models or docs yourself. You decide what runs next, launch subagents, read their ≤10-line results, merge, update the board, and keep the session alive and inside its limits until the end time.

All settings (repo, Project field IDs, tool paths, thresholds, role mapping) are in `.claude/build/config.json`. Read it once at start. Runtime state lives in `<state_dir>/state.json`; the session report in `<state_dir>/reports/`. Agents write no report files: their full notes live in the PR body (builders), the QA/review PR comment, or issue comments (designer). `<state_dir>` (`.build/`) is gitignored.

## 0. Arguments
- **End time (required):** `3h`, `90m`, `2h30m` (relative to now) or `18:30` (local, today; tomorrow if already past). Convert to an absolute ISO timestamp **once** with `date` and store it as `end_at`. If missing, ask for it with AskUserQuestion; do not guess.
- `--milestone "<title>"`: only take issues from that milestone (default: first milestone in `milestone_order` with open issues, then continue into the next).
- `--max-parallel N`: override `pacing.max_parallel_workers` (never above 3).
- `--dry-run`: run preflight and print the first 5 items you would dispatch with role and estimated cost; dispatch nothing.

## 1. Preflight (stop and report if a blocker fails)
Run these in as few tool calls as possible:
0. Load deferred tools in one call: `ToolSearch` with `select:mcp__ccd_session_mgmt__get_usage,TaskStop`. If `get_usage` is not available (e.g. plain CLI), treat plan usage as `unavailable`, run serially and rely on time only.
1. `date` → now; compute `end_at`, `wind_down_at = end_at − max(wind_down_min_minutes, avg task minutes)`.
2. `mcp__ccd_session_mgmt__get_usage` → plan windows (5-hour, weekly) and **this session's** context %. Record a baseline.
   - 5-hour ≥ `five_hour_serial_below_pct` and it resets after `end_at` → tell the user the session can't do real work; stop.
   - Weekly ≥ `weekly_stop_at_pct` → stop.
   - 5-hour ≥ `five_hour_normal_below_pct` and it resets before `end_at` → tell the user how long the session will run serially or cool down until the reset, and offer to delay the start (AskUserQuestion: *Start now* / *Start at reset*).
   - Context of this session > 30 % → recommend starting the run from a fresh session (`/clear`) and ask whether to continue anyway.
3. Disk: `df -g <main_checkout>` free GB. Below `min_free_disk_gb` → run the worktree cleanup (§6 *Worktree cleanup*) once, re-check; still below → stop.
4. Tools: `git lfs version` (blocker for art/level/audio work — if missing, exclude those roles and tell the user `brew install git-lfs && git lfs install`), `gh auth status`, Godot binary `--version`, Blender `--version`.
4b. **Commit signing:** if `git config commit.gpgsign` is true, test that signing works unattended: `git -C <main_checkout> commit-tree -S HEAD^{tree} -m probe </dev/null` (creates a dangling object only; run it exactly like this — macOS has no `timeout`, so don't wrap it, and judge by whether it prints a commit hash, not by stderr noise). If it fails or needs an interactive approval (e.g. 1Password SSH agent locked / per-use approval), agents' commits will fail mid-run → stop and tell the user to unlock the signer (and allow it for the session duration) or decide themselves about signing for this repo. Never change signing config yourself. Signing can also fail **mid-run** (seen: 1Password agent errors that come and go); re-probe before every build dispatch (§4).
5. Repo: `git -C <main_checkout> fetch -q && git status --porcelain` must be clean on `base_branch` (`.claude/worktrees/` is gitignored); pull fast-forward. Run the worktree cleanup (§6) for leftovers from earlier sessions.
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
Skip issues labelled `blocked`, `needs:split` (the split children are in the queue), `needs:human-check` (only a person can do them), issues already in flight, and milestone `Later (optional)`.

**Board sync:** on each queue refresh, add open issues that are missing from the Project (agents should add the ones they create, but check): compare the issue numbers with `gh project item-list <number> --owner <owner> --limit 300 --format json --jq '[.items[].content.number]'`, then `gh project item-add <number> --owner <owner> --url <issue url>` and cache the new item id in `project_items`. Also rebuild the item-id cache whenever an agent reports `NEW_ISSUES`, before you edit those items' Status: `gh project item-list <number> --owner <owner> --limit 300 --format json --jq '[.items[]|{key:(.content.number|tostring),value:.id}]|from_entries' > <state_dir>/project_items.json`. A stale cache makes `item-edit` fail with "field-id must be provided".

Set Status with `.claude/build/board.sh <issue> <todo|in_progress|done>`. It reads the IDs from config, rebuilds a stale cache and adds a missing item to the board itself.

**Role for an item:** first matching `role_by_label` entry by its `area:*` labels, else `default`. `area:design` items go to `game-designer` directly.

**Parallelism:** two items may run at the same time only if their `area:*` labels are disjoint **and** neither depends on the other (an item depends on an earlier open item in the same milestone that its body or the wiki names, or that touches the same system). When unsure, run serially.

## 3. Per-item pipeline
For each picked issue `#n` (set Project Status → In Progress with `gh project item-edit`, using IDs from config; find the item id once via `gh project item-list … --format json --jq` and cache it in state):

1. **Design gate** — if the issue has no `Acceptance criteria` comment (check with `gh issue view n --json comments --jq '[.comments[].body|select(test("Acceptance criteria"))]|length'`): launch `game-designer`. If it returns `split`, drop `#n` and re-queue its children.
   - **Batch gates:** check the next 3–5 queued items at once and give one designer call all of those that lack criteria (it costs about 1 % per batch). Also use a batch to fill an idle slot when no build can start (dependency, perf item running alone, serial mode).
2. **Build** — launch the role's agent with `isolation: "worktree"`, `run_in_background: true`. If the issue also needs art (`NEEDS: art` from a dev, or the criteria mention a model), launch `technical-artist` for a sub-issue in parallel when pacing allows.
3. **QA** — when the build agent returns a PR: launch `qa-tester` (`isolation: "worktree"`, background).
   - FAIL → relaunch the **same role** with the QA findings (max 2 fix rounds per item, then label `blocked`, comment why, move on).
   - **Builder returns `partial` + `NEEDS: design`** (a criterion can't be met as written): launch `game-designer` with the builder's measured numbers, and ask for a ruling posted as a "Design decision" PR comment. Then send the ruling to the **same builder** with `SendMessage` (it keeps its context; a new agent re-derives everything). This counts as a fix round. If the designer's ruling is an untested estimate and the next round fails again, label `blocked` instead of a third round.
   - **Tuning items:** if a builder reports that a no-change control run already fails the gate, don't send another tuning round. Label `blocked` with the control result and recommend a design/tech review of the scenario or model.
   - **Wiki-only FAIL:** if QA fails only on a wiki criterion and the text is ready (staged, or in the PR body), launch `game-designer` to publish it right away, then rerun QA. Don't leave the PR waiting.
   - **Performance items:** don't run a benchmark-dependent build or QA in parallel with other worktree agents (machine load skews timings by 2–3×). Dispatch it alone, and judge a perf verdict only from interleaved before/after runs.
4. **Review** — from milestone `separate_review_from_milestone` onwards, and only for PRs that change code: launch `tech-reviewer` after QA PASS. CHANGES with blocking findings → one fix round, then QA again.
5. **Merge** (only if `merge_policy` allows): if `main` moved in the same area since QA ran (another merge touched the same system), have the reviewer, or a quick QA rerun, verify the PR merged with `origin/main` first. Then run `.claude/build/merge.sh <pr> <issue> <agent ids of this item's worktree agents>`. It checks that every PR check is `pass` (exit 2 and touches nothing otherwise), marks the PR ready, squash-merges, verifies `MERGED`, pulls `base_branch`, sets the board to Done and removes the listed agents' worktrees and branches. On exit 2 with pending checks, wait with a background `gh pr checks <pr> --watch --interval 20`, end your turn and rerun it. The issue closes via `Closes #n`.
   - **Human checks:** if QA reported a `HUMAN_CHECK:` line, file one issue after the merge: title `Human check: <what> (#n)`, labels `needs:human-check` + the item's `area:*`, same milestone, body with what to check and where, assigned to the repo owner. Add it to the board and record it in `state.human_checks`.
   - **Before any cleanup**, `TaskStop` every agent of this item whose task notification said "waiting on its own background work". Agents sometimes hand back their report but leave a background command running, and that keeps their worktree in use.
6. Record the item outcome, duration and usage cost in state. Also record the reviewer's `NITS:` and the builder's `INTERPRETATIONS:` (if not `none`) under `state.nits` / `state.interpretations` with the issue and PR numbers.

New issues created by agents (`qa:found`, sub-issues) enter the queue automatically on the next queue refresh; refresh the queue after every merge, not on every wake.

### Launch prompt template (keep it short — the agent definition holds the role instructions)
```
Issue: #<n> "<title>" in gambarini/racing (milestone <m>).
Branch: issue-<n>-<slug> from origin/main.   [PR: #<pr> — for QA/review/fix rounds]
[QA/review: check out with `gh pr checkout <pr> --detach` — the branch may still be checked out in another worktree.]
[Fix round: `git fetch origin && git checkout --detach origin/issue-<n>-<slug>`, commit, then `git push origin HEAD:refs/heads/issue-<n>-<slug>`.]
Session deadline: <end_at>. Commit and push work-in-progress at least every 20 minutes; if you get stopped, the branch must be usable.
[Fix round: the findings are in the latest QA FAIL / REVIEW comment on PR #<pr> (`gh pr view <pr> --comments`); address only those.]
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
| 5-hour between serial threshold and `five_hour_finish_below_pct` | No builds, fix rounds or new items. Still dispatch cheap steps (QA, review, design-gate batch, merge) for items already in flight, one at a time, so a finished PR doesn't wait hours for a 1 % review. |
| 5-hour ≥ serial threshold with nothing cheap left (or ≥ finish threshold) | Dispatch nothing. If `resetsAt` < `wind_down_at`: cooldown — background `sleep` until `resetsAt` + 2 min, tell the user in one line, resume after. If `resetsAt` is after `wind_down_at` but at least `late_reset_min_minutes` before `end_at`: cooldown until the reset, then only finish in-flight items (§5 *Late finish*). Otherwise wind down. |
| Weekly ≥ `weekly_stop_at_pct` | Wind down. |
| Plan usage `unavailable` / `not_applicable` | Run serially; rely on time only. |
| Estimated cost of next agent + `reserve_pct` > remaining 5-hour % | Don't start it; pick a cheaper role step (QA/merge) or wait for in-flight work. |
| Signing probe (§1 4b) fails | No new build/fix dispatches (they commit); QA, review, design gates and merges continue. Tell the user in one line, re-probe on the next wake. |
| Free disk < `min_free_disk_gb` | Clean up worktrees; if still low, no new worktree agents (designer-only work allowed). |
| Remaining time < estimated duration of the item | Skip to a smaller item (a QA, a design gate, or a `type:task`) or start wind-down. |

**Whole items:** a full item (build + QA + review) costs about `item_cost_pct` of the 5-hour window, so before starting a build check that the item can finish below the serial threshold; otherwise prefer a cheaper step.

**Cost calibration:** record 5-hour `percentUsed` when each agent starts and when it returns; keep a running average per role in `state.cost_pct` and average minutes in `state.minutes` (seed from `default_cost_pct` / `default_task_minutes`). With parallel agents, split the observed delta evenly between them. Use these estimates in the rules above.

## 5. Wind-down and hard stop
- **WIND_DOWN** (watchdog or rule): stop dispatching new items. Let in-flight build agents finish; run QA/merge only if it fits before `end_at`. Use the wait to file the follow-up issues below, so the end is only report writing.
- **Late finish** (little time left before `end_at`): run QA and review of the last PR in parallel instead of in sequence, with a hard time limit in both prompts. Merge only if both pass.
- **HARD_STOP** at `end_at`: `TaskStop` every in-flight agent (they have committed WIP). For each unfinished item: make sure its branch is pushed (if policy allows), leave the PR as draft, comment on the issue with where it stopped (one paragraph, from the agent's last report), keep Project Status = In Progress.
- Kill the remaining watchdog/cooldown background tasks.
- **Follow-ups:** from `state.nits`, file one issue "Tech debt from session <date>" (`type:task`, current milestone) listing each nit with issue/PR. From `state.interpretations`, file one `area:design` issue asking the game-designer to confirm the readings and record them on the wiki. Add both to the board and link them in the report.
- Write the **session report** to `<state_dir>/reports/session-<date>.md`: start/end, items merged (#, PR), items in progress, QA-found issues created, blocked items with reason, open `needs:human-check` issues (`gh issue list --label needs:human-check`), usage used (5-hour Δ, weekly Δ), cost calibration table, recommendations for next session. Publish it to the wiki:
  1. Clone `wiki_git` into a temp dir and run `git config commit.gpgsign false` there (wiki commits are unsigned).
  2. Write the report as `Build-Session-<date>.md` (add `-2`, `-3` for a second session the same day). Write issue/PR refs as links (`[#n](https://github.com/<repo>/issues/n)`), because wiki pages don't auto-link `#n`.
  3. Add one row at the top of the table in `Build-Sessions.md`: date, duration, merged count, one-line highlights, `[[Build Session <date>]]`.
  4. Commit and push with the explicit URL, `git push https://github.com/gambarini/racing.wiki.git HEAD:master` (pre-approved in `.claude/settings.json`). If the push is rejected (a designer pushed meanwhile), `git pull --rebase` and push again, up to 3 times.
- Final message to the user: ≤12 lines summary + link to the wiki session page (`<wiki_url>/Build-Session-<date>`).

## 6. Keeping the orchestrator alive and lean (long runs)
- **Never** read diffs, source files, long logs or full reports in this session. Agents' final messages are ≤10 lines; read an agent's full notes only when a decision needs it, and then only the first 40 lines (`gh pr view <pr> --json body --jq .body | head -40`, or `--json comments --jq '.comments[-1].body'`).
- Use `--json … --jq` on every `gh` call to fetch minimal fields.
- All decisions/outcomes go to `state.json` immediately, so an auto-compaction or a resumed session can continue: on (re)start, if `state.json` exists with `end_at` in the future, **resume** from it instead of starting fresh (re-check in-flight agents; treat unknown ones as stopped and inspect their branch/PR).
- Check this session's context % with `get_usage` at each dispatch:
  - above `orchestrator_context_lean_pct`: no more user-facing progress text except one line per merge; no optional reads.
  - above `orchestrator_context_critical_pct`: wind down early (finish in-flight, write the report) — the next run resumes from state.
- **Watchdog wakes:** when a background `sleep` exits, run `date` and compare with `wind_down_at` / `end_at` before acting. If it exited early (killed, timed out), re-arm it for the remaining seconds instead of winding down.
- **Worktree cleanup:** agent worktrees are not removed automatically once they hold commits. `merge.sh` cleans up the agents you pass it. For leftovers, or after an item is abandoned, run `git -C <main_checkout> worktree list --porcelain`, `git worktree remove --force <path>` for worktrees whose branch is `issue-<n>-*` of that item or detached at an already-merged commit, then `git worktree prune` and `git branch -D` the merged local branches. Never remove a worktree of an in-flight agent. Worktrees can stay **locked** with the reason `claude agent agent-<id> (pid …)`, where the pid is this orchestrator session, not the agent; once that agent id is no longer in `in_flight`, remove it with `git worktree remove -f -f <path>`.
- Between events, end your turn: background agents and the watchdog wake you. Don't poll and don't sleep in the foreground.
- An agent's report can arrive twice: as its hand-back message and again in the task notification, or repeated after a resume. Act on each report once. Check `state.json` (role/agent of that item) before dispatching the next step, so the same QA or merge isn't launched twice.
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
  "nits": [{"issue": 1, "pr": 60, "text": "file.gd:23 per-tick Dictionary"}], "interpretations": [{"issue": 1, "pr": 60, "text": "…"}],
  "done": [{"issue": 1, "pr": 60, "minutes": 34, "cost_pct": 7}],
  "blocked": [{"issue": 3, "reason": "…"}],
  "created_issues": [61, 62], "human_checks": [{"issue": 70, "for": 60}],
  "cost_pct": {"gameplay-developer": 6.5},
  "minutes": {"gameplay-developer": 31}
}
```
Write each agent's id into `in_flight` from the Agent tool result, in the call right after the dispatch. Never write a placeholder id first and patch it later. Take `started_at` from `date`, not from an estimate.

## 8. Guardrails
- Respect `merge_policy`; never push to `base_branch` directly, never force-push, never merge a PR without QA PASS (and review APPROVE where required).
- Never close issues manually except duplicates and items whose deliverable has no PR (wiki-only or decision-only): close those only after verifying the deliverable exists (e.g. the wiki commit is on the remote) and comment the evidence. Otherwise merging with `Closes #n` closes them.
- Don't start `start_session` sessions for workers; use the Agent tool (background, worktree isolation).
- Don't change the roadmap's milestone order or dates; propose changes in the session report instead.
- If an agent reports that a tool call was denied by the permission check, don't run that call for it. Note it in the report (and ask the user to add an allow rule) instead.
- If an agent reports `blocked` for an environment reason (missing tool, auth), stop dispatching that role and report it to the user immediately in one line.
