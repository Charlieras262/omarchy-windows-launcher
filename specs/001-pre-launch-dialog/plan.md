# Implementation Plan: Pre-launch dialog and launch/close progress

**Spec**: `spec.md` · **Constitution**: `.specify/memory/constitution.md`
**Status**: Draft — spec clarifications C1–C5 are resolved; design decisions marked
**(spike)** stay provisional until the Phase 0 spikes in `tasks.md` confirm them.

## 1. What the system looks like today (verified on this machine)

- Entry point: `~/.local/share/applications/windows-vm.desktop` →
  `uwsm app -- omarchy-windows-vm launch`.
- `/usr/bin/omarchy-windows-vm launch` brings the container up (`priv up_wait`), then runs
  `xfreerdp3 … /dynamic-resolution …` in the foreground and, when it returns, runs `priv down`
  unless `--keep-alive` was given. It has no hooks and no options for monitors or disks.
- `priv` elevates with `pkexec /usr/bin/omarchy-windows-vm __priv <action>`, or runs directly
  when the user has opted into sudoless Docker. `__priv` accepts only
  `write_compose|up|up_wait|down|status|remove`.
- The compose file is `/var/lib/omarchy/windows/docker-compose.yml` (root:docker, 0640) and is
  only written by the validated `write_compose` action. It maps `/dev/kvm` and `/dev/net/tun`
  only. Its QEMU monitor is a unix socket inside the container: `/run/shm/monitor.sock`.
- The Omarchy shell (`omarchy-shell`, Quickshell) hosts plugins described by `manifest.json`;
  kind `overlay` is a fullscreen/summoned window. A plugin can be summoned with
  `omarchy-shell shell summon <plugin-id> '<json>'` and returns results through files
  (the image-picker pattern). The shell ships `Ui/Toggle.qml`, `Ui/MultiSelect.qml`,
  `Ui/Button.qml`, `Ui/ConfirmDialog.qml`.

## 2. Constitution check

| Principle | How the design complies |
|-----------|-------------------------|
| I No new deps | QML plugin + bash only; `xfreerdp3`, `docker`, `lsblk`, `udisksctl`, `jq` already present. |
| II Don't modify system files | New user plugin, new user wrapper, a *separate* root-owned override compose; packaged files untouched. |
| III Least privilege | One small root-owned helper, closed-set arguments, device list re-derived by root from `lsblk` (see §5). |
| IV Native look | Overlay plugin built on the shell's `Ui/` components and theme singleton. |
| V Safe by default | Disk list excludes system disks; unmount is explicit; release on every exit path. |
| VI Fail visible | State machine with an explicit `failed` state, always rendered. |
| VII Spec-driven | This plan traces every item to a FR in `spec.md` (§8). |

## 3. Architecture

```
 desktop entry ─▶ omarchy-windows-launcher (bash, user)         ← orchestrator
                    │  summon dialog  ──▶ shell plugin: Dialog.qml  ─▶ answers.json
                    │  write state    ──▶ $XDG_RUNTIME_DIR/omarchy-windows-launcher/state.json
                    │                          ▲
                    │                          └── shell plugin: Progress.qml (reads state, renders)
                    ├─ priv helper (root) ◀── pkexec  ─ up / attach disks / down / release
                    └─ xfreerdp3 (user) ── waits for exit ─▶ close handling per option 1
```

Three deliverables:

1. **`bin/omarchy-windows-launcher`** — bash orchestrator and single source of truth for the
   session state machine. Installed to `~/.local/bin/`.
2. **Shell plugin `charlieras262.windows-launcher`** (`kinds: ["overlay"]`) with two views:
   `Dialog.qml` (options) and `Progress.qml` (launch + shutdown). It contains no business logic;
   it renders `state.json` and writes `answers.json`.
3. **`libexec/omarchy-windows-launcher-priv`** — root-owned helper, installed once by `install.sh`
   into `/usr/local/libexec/`, run via `pkexec`. Needed only for the actions the packaged script
   cannot do (disk attach/release with an override compose).

`install.sh` / `uninstall.sh` copy and remove the three pieces, re-point the desktop entry, and are
idempotent (FR-017, NFR-004). The desktop entry is user-owned, so no system file is touched.

## 4. Session state machine

States written to `state.json` (`{stage, percent, message, error, disks[], monitors, keepAlive}`):

`idle → dialog → authorizing → preparing-disks → starting → booting → connecting → running →
closing → stopped`, plus terminal `failed` and `cancelled`.

- `percent` is derived from stage weights, not time, and never decreases.
- The orchestrator holds a lock (`flock` on a file in the runtime dir) so a second launch only
  re-summons the existing Progress view (FR-015).
- Every exit path (including `trap` on signals) runs one `finalize` function. Disk-bearing sessions
  follow the ordered release of D9 (FR-020); the VM is stopped or reported per option 1 (FR-010, FR-014).

## 5. Key design decisions

### D1 — Options dialog (FR-001..006, US1)
Overlay plugin view with two `Toggle`s, a conditional `MultiSelect` (shown when option 3 is on, with
the refresh button the component already provides), **Start**/**Cancel**. It is summoned by the
orchestrator with a JSON payload (defaults + current disk list) and answers by writing `answers.json`
and touching a done-file — the same file round trip the image picker uses, so the orchestrator can
block on it from bash without any IPC library.

### D2 — Stop-on-close (FR-003, US2) **(spike)**
Preferred: the orchestrator owns the whole flow and does **not** call `omarchy-windows-vm launch`
(which always blocks on RDP and then stops). It brings the VM up through the privileged path, runs
`xfreerdp3` itself with the same arguments as the packaged launcher, and decides on `down` itself.
Fallback if copying the RDP argument list proves fragile across Omarchy updates: call
`omarchy-windows-vm launch --keep-alive` and run `down` from the orchestrator when option 1 is on,
with a `PATH` shim for `xfreerdp3` to inject extra flags. Spike S1 decides which.

### D3 — All monitors, window placement and bar hiding (FR-004, FR-019, FR-024..026, US3)
**Two parts, both required.** (1) FreeRDP must be told about the monitors (`/multimon:force /f`, injected by the shim),
otherwise the remote desktop is a single-monitor session no matter how big the window is — a window stretched over two
screens would just show one monitor's desktop. This was learned the hard way: a first version that dropped `/multimon` and
only resized the window showed one monitor. (2) Hyprland then floats and stretches that window over the same area, because a
floating window may straddle outputs and the packaged launcher already passes `/dynamic-resolution`.

`lib/layout.sh` computes the box from `hyprctl monitors -j`: left edge of the leftmost monitor to the right edge of the
rightmost, top-aligned, covering the whole canvas (logical pixels, scale applied, rotated outputs swapped; on this machine
portrait DP-1 + ultrawide DP-2 → `0 0 4880 2560`; the `min` mode that limits the height to the shortest monitor is kept for
other uses). Placement uses the Lua dispatchers of this Hyprland (0.56), verified on a throwaway window: `float` and `move`/`resize`
with `window = "address:…"`. The `/f` client starts **fullscreen**, and a fullscreen window cannot be floated or sized (float only sets
the flag), so placement first lifts fullscreen with `fullscreen({ mode = "fullscreen", action = "unset" })`. Single-monitor path untouched.
Observed: Hyprland accepts a 4880-wide floating window (no clamping), but the **X11** FreeRDP client (it runs through XWayland)
re-requests its own size while the session comes up, so the watcher re-asserts the box until the window has held it for a few
consecutive ticks, then stops so a manual resize afterwards is respected; every attempt is logged to
`$XDG_RUNTIME_DIR/omarchy-windows-launcher/placement.log`.

Window identity and rules: the shim records the RDP client's PID; the launcher finds its windows by PID, not by class (the
class is only knowable once a real session is open). The user's own rule by title (`o.window({ title = "Windows VM - Omarchy" },
{ workspace = "4" })`) keeps working because neither title nor workspace of the main window is touched. A watcher runs for the
whole session and moves every other window of that PID (popups, dialogs) to the main window's workspace with
`hl.dsp.window.move({ workspace, follow = false })`. Window rules cannot express "same workspace as another window", hence the
watcher. The launcher's own overlay windows (dialog, progress) are layer-shell surfaces and are not tied to a workspace.
Observed on this machine: Hyprland accepts a 4880x1440 floating window at 0,0 (no clamping), but the FreeRDP client is the
**X11** build (it runs through XWayland) and re-requests its own size while the session comes up, which left a small floating
window when the geometry was applied only once. The watcher therefore re-asserts the box until the window has held it for a few
consecutive ticks, then stops so a manual resize afterwards is respected; every attempt is logged to
`$XDG_RUNTIME_DIR/omarchy-windows-launcher/placement.log`. 

Bar: before connecting, the orchestrator records whether the bar is currently hidden, then runs
`omarchy toggle bar on` (**inverted wording**: the command drives a flag named `bar-off`, so `on` = flag present = bar hidden and `off` = bar shown; the first version had them swapped and hid the bar only after the session) (stock command; it sets the toggles flag and nudges the shell). `finalize` runs
`omarchy toggle bar on` only if the orchestrator was the one that hid it, so a bar the user had already
hidden stays hidden. It is restored on every exit path, including a failed launch after hiding. The
state it needs ("we hid the bar") lives in the session state file so a restarted orchestrator can still
restore it.

### D4 — Eligible disks (FR-005..007, US4)
Computed by `lsblk -J -b -o NAME,PATH,TYPE,SIZE,MODEL,LABEL,FSTYPE,TRAN,RM,HOTPLUG,MOUNTPOINTS`
as: every whole disk (`TYPE=disk`, so removable USB media and secondary internal data disks alike) **minus**
the system set: any disk with a partition mounted at `/`, `/boot`, `/home` or used as swap, any disk
underlying the VM's storage anchors (`/var/lib/omarchy/windows/mounts/...`), any disk of a device-mapper /
LUKS stack that holds those mounts (this machine's root is on `nvme0n1p2` → `root`), and `zram`/loop
devices. Selection unit = whole disk (C2); the UI shows partitions only as descriptive text. The rule is
"exclude the system", not "include only USB", so a data disk such as `/media/Data` is eligible while the
root NVMe is not. The root helper **recomputes** this
same set itself and rejects anything not in it, so a tampered `answers.json` cannot name `/dev/nvme0n1`.

### D5 — Attaching disks (FR-008..010) **(spike)**
Candidates, in order of preference:

- **A. Compose override**: the root helper writes `/var/lib/omarchy/windows/launcher.override.yml`
  (root-owned, regenerated per session, deleted on release) adding `devices: [/dev/sdX]` and the
  image's per-disk environment variables, then runs
  `docker compose -f docker-compose.yml -f launcher.override.yml up -d`. Needs the container to be
  recreated, so it only applies at a fresh start. When the VM is already running, the orchestrator shows
  the decided choice (spec §5): **Restart the VM with these disks** or **Continue without these disks**
  (no default, Cancel aborts), rendered in the Progress view as a two-button prompt.
- **B. QEMU hot-plug** through `/run/shm/monitor.sock` once the container runs. No recreation, but the
  device node must exist inside the container and the block backend must be added by hand.

Spike S3 tests both with a throwaway USB stick and decides. Either way: the host unmount goes through
`udisksctl unmount` (FR-008, after the user accepts), and automounting (`udiskie` on this system) must be
paused for the target disks during the session so it cannot remount them under the VM
(this bit us during manual testing). Release re-enables it for those disks and lets the host re-detect them.

### D6 — Progress source (FR-011, NFR-002) **(spike)**
Stages up to "starting" come from the orchestrator itself. The "booting" stage needs a real signal without
needing Docker access from the UI:
- **Preferred**: the VM's own web endpoint on `127.0.0.1:8006` (the dockur status page shows install/boot
  messages). Spike S4 checks whether it exposes machine-readable boot status.
- **Fallback**: `docker logs` through the privileged helper, matching `Windows started successfully`
  (what the packaged `up_wait` already does) — coarse, three-step progress.
- **Last resort**: TCP probe of `3389` after the container reports running.
Progress never exposes credentials (NFR-003).

### D7 — Progress and shutdown windows (FR-011..013, US5)
`Progress.qml` is one view with two modes (`launch`, `shutdown`), driven purely by `state.json`
(`FileView`/`Process` watch inside the shell). Auto-dismiss on `running` and, after 3 s, on `stopped`.
When option 1 is off the "still running" message is a regular `omarchy-notification-send` toast, not a window.

### D8 — Privilege (FR-016, Constitution III)
Prompt count is minimised: one `pkexec` call covers authorizing + preparing + starting. If the user has
sudoless Docker, the helper is skipped for the VM-only path and the stage list omits "authorizing".
The helper's entire interface is a closed verb set: `up [--disk PATH]… `, `down`, `release`, with
argument validation modelled on the packaged `valid_*` checks. It is not a general docker wrapper.

### D9 — Clean release and shutdown/reboot ordering (FR-020..023, US6)

Two layers, because neither alone is enough: the first prevents trouble on the normal paths, the
second guarantees recovery when the first is cut short.

**Layer 1 — ordered release at close.** `finalize` for a session with disks runs, in order:
`graceful guest stop` (the image already turns a container SIGTERM into a Windows shutdown and the
compose allows `stop_grace_period: 2m`) → wait for the container to be `exited` → helper `release`
(detach, return disk to the host, lift the per-disk automount pause) → restore bar. The helper never
releases while the container is running.

**Priority over host shutdown/reboot.** The orchestrator holds a systemd *delay* inhibitor
(`systemd-inhibit --what=shutdown --mode=delay`, no extra package) for as long as any disk is attached
and starts the guest shutdown as soon as it receives the termination signal or the logind
`PrepareForShutdown` signal. Facts on this machine: Omarchy's `omarchy system shutdown` schedules
`systemctl poweroff` two seconds out while closing all windows (which closes the RDP window and
triggers `finalize` concurrently), and logind is configured with `InhibitDelayMaxSec=15`
(`/etc/systemd/logind.conf.d/20-inhibit-delay.conf`). So the hold is limited to about 15 seconds by
system policy; a Windows shutdown can take longer. We do **not** raise that limit (it is a system file;
Constitution II). Spike S6 measures the real shutdown time. If Docker's own stop at host poweroff
already waits for the container (to be confirmed in S6), Layer 1 is covered by it and the inhibitor
is a bonus; otherwise Layer 2 carries the guarantee.

**Layer 2 — reconcile at start (FR-022).** Before any launch work, `reconcile` reads the previous
session's state file and compares it with reality (`docker inspect`, `lsblk`, automount pause list,
bar toggle). It repairs: container still up → graceful stop first; disks still listed as attached while
the container is down → release; automount still paused → lift; bar hidden by us → restore. It marks
disks with `unclean=true` when the previous session ended without a confirmed guest stop, shows that in
the Progress view (FR-023), and refuses to mount them on the host automatically. Because it runs on
every launch, correctness no longer depends on winning a race with the shutdown order.

**Why not "only at start"?** It would leave disks attached through a whole reboot with no guest
shutdown, risking NTFS corruption. **Why not "only at close"?** The host may power off before it finishes.
Layer 1 minimises risk; Layer 2 removes the dependency on timing.

## 6. Repository layout

```
bin/omarchy-windows-launcher
libexec/omarchy-windows-launcher-priv
plugin/manifest.json
plugin/Dialog.qml
plugin/Progress.qml
install.sh  uninstall.sh
specs/001-pre-launch-dialog/{spec,plan,tasks}.md
tests/                # bats-free shell tests (plain bash) for disk filtering, state machine, arg validation
README.md  LICENSE (GPL-3.0)
```

## 7. Risks

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Packaged `omarchy-windows-vm` internals change (`__priv` actions, RDP args) | Wrapper breaks after update | Prefer own helper over undocumented `__priv`; tests that diff our RDP args against the packaged script; version check at start. |
| Wrong disk attached (data loss) | Severe | Closed-set recompute in root helper; system-disk exclusion with tests; explicit unmount confirmation; never auto-select. |
| Shell plugin API shifts | UI stops loading | Use only documented kinds/components; pin `schemaVersion`; degrade to stock launcher with a message. |
| Host shuts down before the guest finishes (inhibitor limited to ~15 s by logind) | Disk left dirty | Guest shutdown starts at once; Docker's own graceful stop; reconcile-at-start (D9 layer 2); dirty report instead of silent repair. |
| Automount (udiskie) races with attach | Disk busy / mounted twice | Pause automount per disk for the session (D5). |
| Root helper becomes an escalation path | Severe | Root-owned install path, closed verbs, no shell-outs with interpolated input, review checklist in `tasks.md`. |
| The manual changes made earlier (privileged container, `/dev/bus/usb` volume, `usb-host` ARGUMENTS) conflict with the override | Confusing state | Document and offer a one-step revert (backup `docker-compose.yml.bak` / `.bak2` already exist). |

## 8. Traceability

| Requirement | Design |
|---|---|
| FR-001,002 | D1 |
| FR-003 | D2, §4 finalize |
| FR-004 | D3 |
| FR-005,006,007 | D1, D4 |
| FR-008,009,010 | D5, §4 finalize |
| FR-011,012,013 | D6, D7 |
| FR-014,015,016 | §4, D8 |
| FR-020,021 | D9 layer 1 |
| FR-022,023 | D9 layer 2 |
| FR-017,018 | §3 install/uninstall, constitution II |
| NFR-001..005 | D1, D6, D7; strings in one file |
