# TEST-REPORT

Living per-iteration test report, maintained per the Testing Discipline iron
rule (main repo AGENTS.md, 2026-09-06).

Layer definitions: L1 static (bash -n, shellcheck, gitleaks, no-Chinese scan),
L2 config validation, L3 runtime smoke in a disposable environment, L4
host-level lifecycle.

---

## 2026-09-06T20:23:39Z — commit 60b97eb (Round 2 Day 11 backfill: CI pipeline, shellcheck fixes)

**Layers executed: L1, L2. L3/L4 not run.**

| Check | Result |
|---|---|
| L1 bash -n sweep (22 files + mb) | PASS |
| L1 shellcheck -S warning gate | PASS (0 findings; 18 fixed in iter/backup-ci-tests: 16 SC2155 splits, 2 SC2034 annotations) |
| L1 gitleaks history scan | PASS (exit 0) |
| L1 no-Chinese content scan | PASS |
| L2 cron sanity: 3 cron examples have 5-field schedules | PASS (3 ok, 0 fail) |

Defects found during this development cycle (fixed pre-push, CI-verified):

- 16 SC2155 declare-and-assign sites (mb entrypoint, lib/common.sh,
  lib/drill.sh) masked command-substitution failures under set -e; split so
  failures propagate - the correct semantics for backup scripts.

Known issues (open): none recorded this cycle.

Untested (honest boundaries):

- L3 runtime smoke: no backup was run against a real backend this cycle;
  strategies are config-validated only. The Round 3 restore fixture
  (iter/backup-restore-fixture: seeded data -> restic backup to MinIO ->
  isolated restore -> hash verification) is the committed next runtime
  evidence.
- L4 host-level: recovery on a real host, append-only enforcement, and key
  rotation drills not run - blocked on backend credentials and a disposable
  target; "ransomware-resistant" claims stay out of docs until the
  permission separation is tested.
