# Tasks: Pre-launch dialog and launch/close progress

## Progress (kept current)

**Done and unit-tested with fakes (no real VM touched):** state file + lock, disk eligibility, shell overlay
plugin (loads in an isolated Quickshell, dialog writes answers, progress renders state), orchestrator for options
1 and 2 (close-on-exit, multi-monitor flags, bar hide/restore, failure paths, single-session lock, user launch
wrapper honored), install/uninstall.
**Decision taken for the MVP (resolves S1 provisionally):** delegate bring-up to the packaged launcher via
`omarchy-windows-vm launch --keep-alive` (or the user's own wrapper, recorded by `install.sh`), detect the RDP window
with a PATH shim for `xfreerdp3`, and stop with `omarchy-windows-vm stop`. No private `__priv` internals are used and no
root code exists yet.
**Not yet validated live:** the full flow against the real VM and the real shell (needs `./install.sh` and a launch).
**Not started:** external disks (Phase 5, needs the root helper), clean release and reconcile (D9), real boot-progress
signal (S4, needs a running VM), S1/S2/S3/S4/S6 spikes against the real VM.

Derived from `plan.md`. `[P]` = can run in parallel. Each task names the requirement it serves.
Do not start Phase 1 until the Phase 0 spikes are recorded in `plan.md` and every
clarification in `spec.md` §7 is resolved (done as of this revision).

## Phase 0 — Spikes (answer unknowns; no production code)

- [ ] **S1** Compare "own the flow" vs `--keep-alive` + `xfreerdp3` shim: confirm that the orchestrator can
      reproduce the packaged RDP arguments and bring the VM up without calling `__priv`. Record the choice (D2). — FR-003, FR-018
- [ ] **S2** [P] Live check of the stretched floating window (DONE for the dispatchers on a throwaway window; still to confirm with the real RDP
      window: dynamic resolution follows the size, mixed-DPI). Replaces the FreeRDP `/multimon` approach. — FR-004, FR-026
- [ ] **S3** [P] With a throwaway USB stick, try attach approach A (compose override) and B (QEMU hot-plug via
      `/run/shm/monitor.sock`); verify read/write from Windows, clean release, and udiskie behaviour. Record the choice (D5). — FR-008..010
- [ ] **S4** [P] Inspect `http://127.0.0.1:8006` for machine-readable boot status; if none, confirm the log-line
      fallback. Record the choice (D6). — FR-011, NFR-002
- [x] **S5** [P] Confirm the shell can summon a user overlay plugin with a JSON payload and read back a file result;
      measure dialog latency. — NFR-001, FR-001

- [ ] **S6** [P] Measure how long this Windows VM takes to shut down; test what happens to the container when the host
      powers off with it running (does Docker's stop wait the full grace period? is the 15 s logind delay enough?); confirm a
      delay inhibitor can be held from a user process and released on completion. Record results in D9. — FR-020, FR-021

## Phase 1 — Foundations

- [x] **T01** Create `plugin/manifest.json` (id `charlieras262.windows-launcher`, kind `overlay`, `keepLoaded` as the
      spike dictates) and an empty view that loads. — FR-013
- [x] **T02** Define the `state.json` and `answers.json` schemas (documented in `plan.md` §4) and a bash library to
      read/write them atomically. — FR-011
- [x] **T03** [P] Implement `list-disks` ("every whole disk minus the system set", D4) as a standalone function with unit tests using
      recorded `lsblk -J` fixtures: USB stick listed; a secondary data disk listed; NVMe root (including its LUKS/dm stack), `/boot`,
      `/home`, swap, `zram` and VM-storage disks excluded. — FR-005..007
- [x] **T04** [P] Implement the session lock and the `finalize` trap skeleton (release → stop/report). — FR-014, FR-015
- [x] **T05** `install.sh` / `uninstall.sh` (idempotent): copy plugin and wrapper, re-point the desktop entry, install the root
      helper with `sudo`, and restore stock on uninstall. Test round trip leaves `git status`-style identical file trees. — FR-017, FR-018

## Phase 2 — Dialog (US1, US2) — MVP

- [x] **T10** `Dialog.qml`: two `Toggle`s with the specified defaults, Start/Cancel, `Esc`/`Enter`, full keyboard
      navigation. — FR-001, FR-002
- [x] **T11** Orchestrator: summon dialog, wait for result, handle Cancel with zero side effects (no privilege prompt). — US1.2
- [x] **T12** Implement option 1 end to end: up → RDP → `down` or leave running; reconnect to a running VM. — FR-003, US2
- [ ] **T13** Test: scripted run covering US1.1–US1.4 and US2.1–US2.3 against the real VM. — US1, US2

## Phase 3 — Progress and shutdown windows (US5)

- [x] **T20** `Progress.qml` launch mode: stages, percent bar, message line, themed. — FR-011
- [ ] **T21** Wire the booting signal chosen in S4; add the adaptive stage list (no "authorizing" with sudoless Docker). — FR-011, edge cases
- [ ] **T22** Failure rendering: failed stage, plain reason, Close/Retry; authorization-declined path. — US5.4, FR-016
- [ ] **T23** Shutdown mode and the "still running" toast. — FR-012, US5.5, US5.6
- [ ] **T24** Test: simulated failures (Docker stopped, auth declined, boot timeout, RDP crash) each end in a reported, known state. — FR-014

## Phase 4 — All monitors (US3)

- [x] **T30** Orchestrator: build RDP monitor flags from `hyprctl monitors -j` per S2; single-monitor path unchanged. — FR-004
- [x] **T33** Float, resize and move the main window across all monitors (`lib/layout.sh`, tested against fixtures and a fake `hyprctl`). — FR-026
- [x] **T34** Watcher keeps the RDP client's popups on the main window's workspace; user's title rule untouched. — FR-024, FR-025
- [x] **T32** Hide the bar with `omarchy toggle bar off` when option 2 is on; record whether it was already hidden; restore with
      `omarchy toggle bar on` in `finalize` on every exit path only if we hid it. Test: normal close, failed launch after hiding,
      killed orchestrator, bar already hidden beforehand. — FR-019, US3.2, US3.3
- [ ] **T31** Dialog: option 2 wired; test with 1 and N monitors. — US3

## Phase 5 — External disks (US4) — highest risk, last

- [ ] **T40** Dialog: option 3 reveals `MultiSelect` fed by `list-disks`, with refresh; zero selection = off. — FR-005, FR-006, US4.1–4.3
- [ ] **T41** Root helper `omarchy-windows-launcher-priv`: closed verbs `up`, `down`, `release`; recompute eligibility as root and
      reject anything outside it; tests for tampered `answers.json` (e.g. naming the root disk). — Constitution III, FR-007
- [ ] **T42** Unmount flow with explicit user confirmation and "skip this disk" path; pause automount per disk. — FR-008, US4.5
- [ ] **T43** Attach per the S3 decision; surface `preparing-disks` stage. — FR-009
- [ ] **T44** Release on every exit path, including killed launcher and failed boot; verify disks return mountable on Linux. — FR-010, US4.6
- [ ] **T45** Edge cases: disk unplugged during boot; VM already running with selected disks → restart/continue prompt (no default,
      Cancel aborts, warn that restarting loses unsaved Windows work). — spec §5
- [ ] **T47** Ordered release in `finalize`: graceful guest stop → wait for container exited → helper `release` → restore automount;
      the helper refuses `release` while the container is running (test). — FR-020
- [ ] **T48** Shutdown/reboot priority: hold a delay inhibitor while disks are attached; start the guest shutdown on SIGTERM and on
      `PrepareForShutdown`; verify with `omarchy system shutdown` and `omarchy system reboot` while a disk is attached. — FR-021, US6.2
- [ ] **T49** `reconcile` at the start of every launch: detect and repair leftover container, attached disks, paused automount and
      hidden bar; report in the Progress view; refuse to continue if it cannot reconcile. Tests: kill the orchestrator mid-session,
      kill the container, simulate a reboot with a stale state file. — FR-022
- [ ] **T4A** Dirty-disk reporting: mark `unclean` when the guest stop was not confirmed; message the user; never auto-mount or
      auto-repair on the host. — FR-023, US6.4
- [ ] **T46** Security review checklist run on the helper before it is allowed in `install.sh` (no interpolated shell, no user-writable
      inputs read as root, paths canonicalized, argument allow-list). — Constitution III

## Phase 6 — Polish

- [ ] **T50** README: install, uninstall, how it interacts with `omarchy windows vm`, how to revert the manual compose edits. — FR-017
- [ ] **T51** [P] Centralize UI strings in one file. — NFR-005
- [ ] **T52** [P] Verify no credentials appear in `state.json`, logs, notifications or the UI. — NFR-003
- [ ] **T53** Re-run the whole acceptance checklist in `spec.md` §8; tag `v0.1.0`.
