# Feature Spec: Pre-launch dialog and launch/close progress for the Omarchy Windows VM

**Feature ID**: 001-pre-launch-dialog
**Status**: Clarified — all open questions resolved (see §7); ready for planning review
**Constitution**: `.specify/memory/constitution.md`

> This document says **what** the user gets and **why**. It contains no
> implementation choices; those live in `plan.md`.

## 1. Background

Omarchy ships a Windows VM (`omarchy windows vm`). Launching it today:

- starts the container and connects an RDP window with no questions asked;
- always shuts the VM down when the RDP window closes;
- uses one monitor only;
- gives no way to hand an external disk to Windows (for example to repair an NTFS
  volume) without hand-editing a root-owned compose file;
- shows progress only as terminal text, which is invisible when the VM is started
  from the application launcher (`Super + Space`).

The user wants to decide these things at launch time, from a native dialog, and to
see what is happening while the VM starts and stops.

## 2. User scenarios

### US1 — Choose session options before the VM opens (P1)

When I open "Windows" from the launcher, a dialog appears before anything starts and
asks me three things. I confirm with **Start** or abort with **Cancel**.

| # | Option | Default |
|---|--------|---------|
| 1 | Close the VM when the window is closed | **On** |
| 2 | Use all monitors | **Off** |
| 3 | Mount external disks | **Off** |

**Acceptance scenarios**

1. *Given* I open Windows, *when* the dialog appears, *then* option 1 is on and
   options 2 and 3 are off, and no container has been started yet.
2. *Given* the dialog is open, *when* I press **Cancel** or `Esc`, *then* nothing is
   started, nothing is changed, and no privilege prompt appears.
3. *Given* the dialog is open, *when* I press **Start**, *then* the dialog closes and
   the progress window (US5) takes over.
4. *Given* the dialog is open, *then* every control can be reached and toggled with
   the keyboard, and `Enter` triggers **Start**.

### US2 — Decide what happens to the VM when its window closes (P1)

**Acceptance scenarios**

1. *Given* option 1 was **on**, *when* I close the Windows window, *then* the VM is
   shut down (the container is stopped) and I am told when that finished.
2. *Given* option 1 was **off**, *when* I close the Windows window, *then* the VM
   keeps running in the background and I am told so, including how to stop it.
3. *Given* the VM is still running from an earlier session (option 1 was off),
   *when* I open Windows again, *then* the dialog still appears, and the session
   reconnects to the running VM without restarting it.

### US3 — Use all monitors (P2)

**Acceptance scenarios**

1. *Given* option 2 is **on** and I have N connected monitors, *when* the Windows
   window opens, *then* it is a single **floating** window that starts at the left edge of
   the leftmost monitor and reaches the right edge of the rightmost one, aligned to the top,
   and covers the whole multi-monitor area (parts beyond a shorter monitor are simply outside
   the screens); the remote desktop sees every monitor (one canvas, not one monitor); and the
   Omarchy bar is hidden so it does not overlap the VM.
2. *Given* the bar was hidden by this feature, *when* the Windows window closes (or the
   launch fails or is cancelled after the bar was hidden), *then* the bar is shown again.
3. *Given* the bar was **already hidden** before I launched, *then* it is left hidden
   afterwards (this feature restores only what it changed).
4. *Given* option 2 is **off**, *then* the window behaves exactly as it does today
   (single monitor, today's scaling rules) and the bar is not touched.
5. *Given* only one monitor is connected, *when* option 2 is on, *then* the session
   behaves as a normal single-monitor session (bar still hidden, per scenario 1) and no
   error is shown.

### US4 — Mount external disks (P2)

**Acceptance scenarios**

1. *Given* option 3 is **off**, *then* no disk list is visible and no extra disk is
   given to the VM.
2. *Given* I turn option 3 **on**, *then* a multi-select field appears with the
   eligible disks; each entry shows enough to recognise it (name/model, label if any,
   size, and its partitions). Eligible means: removable volumes such as USB sticks, and
   storage units that are not part of the Linux system (for example a secondary internal
   data disk). The unit of selection is the **whole disk**.
3. *Given* the list is open, *then* I can select zero, one or several disks. With
   zero selected, **Start** behaves as if option 3 were off.
4. *Given* I selected disks and pressed **Start**, *when* Windows has booted, *then*
   each selected disk is visible to Windows and usable (read/write).
5. *Given* a selected disk is currently mounted on Linux, *then* before the VM
   starts I am told which mounts must be released, and the disk is released only if
   I agree; if I decline, the disk is skipped and the rest of the launch continues.
6. *Given* the VM stops, *then* the disks are returned to Linux in a usable state and
   are not left attached to a stopped container.
7. *Given* a system disk (anything holding `/`, `/boot`, `/home`, swap, or the VM's
   own storage) exists, *then* it never appears in the list.

### US6 — Disks are always released cleanly, even around a host shutdown or reboot (P1)

When disks are attached to the VM and the VM closes — because I closed the window, because
the VM was stopped, or because I shut down or reboot the computer — the disks must be handed
back in a consistent state. Cleanup takes priority over the shutdown/reboot request, and if
cleanup could not finish before the machine went down, the next launch repairs the leftovers
before doing anything else.

**Acceptance scenarios**

1. *Given* disks are attached, *when* the VM closes for any reason, *then* Windows is first asked
   to shut down normally (so it flushes its writes), the VM is confirmed stopped, and only then
   are the disks released back to Linux. Disks are never released while the guest is still running.
2. *Given* disks are attached, *when* I shut down or reboot the computer (including with Omarchy's
   own shutdown/reboot commands), *then* the guest shutdown starts immediately and the host
   shutdown is held for as long as the system allows while it finishes.
3. *Given* the host shutdown could not wait long enough, *when* I next open Windows, *then* before
   the dialog does anything else the launcher detects the leftover session, makes sure no container
   is still holding a disk, restores what the previous session changed (automount paused for those
   disks, bar hidden), and tells me what it did.
4. *Given* a disk was not shut down cleanly, *then* the launcher tells me it may need a disk check
   in Windows, and does not try to repair it silently.
5. *Given* no disks were attached, *then* none of the above adds any delay to closing or shutdown.

### US5 — See launch and shutdown progress (P1)

**Acceptance scenarios**

1. *Given* I pressed **Start**, *then* a window appears at once showing the current
   stage and overall progress, with a text line describing what is happening.
   Stages shown, in order: authorizing → preparing disks (only if any selected) →
   starting the VM → waiting for Windows to boot → connecting the display.
2. *Given* the VM is booting, *then* the progress window keeps updating and does not
   look frozen for more than a few seconds at a time.
3. *Given* the Windows window has appeared, *then* the progress window closes by
   itself.
4. *Given* a stage fails or times out, *then* the progress window stays open, shows
   which stage failed and why in plain language, offers **Close** (and **Retry** where
   it makes sense), and leaves the VM in a known state (see FR-014).
5. *Given* the Windows window closes with option 1 on, *then* a second window shows
   "Shutting down Windows…", then "Windows stopped" (including that attached disks were
   returned), and dismisses itself after a few seconds.
6. *Given* the Windows window closes with option 1 off, *then* a short notice (not a
   blocking window) says the VM is still running and how to stop it.
7. *Given* the VM start requires an authorization prompt, *then* the progress window
   says it is waiting for authorization instead of looking stuck.

## 3. Functional requirements

> Numbering follows the request, which lists items 1, 2, 3 and 5 (there is no item 4).
> If an item was lost, add it as a new user story.

- **FR-001** Launching Windows from the application launcher MUST show the options
  dialog before any container is started or any privilege is requested.
- **FR-002** The dialog MUST offer exactly the three options of US1 with the stated
  defaults, plus **Start** and **Cancel**.
- **FR-003** Option 1 on ⇒ the VM is stopped after the Windows window closes; off ⇒
  it is left running.
- **FR-004** Option 2 on ⇒ the Windows window is one window spanning every connected
  monitor; off ⇒ current single-monitor behaviour.
- **FR-024** The user's own Hyprland window rules for the Windows window (for example the one that
  sends it to workspace 4) MUST keep applying. The launcher never renames the window, never forces its
  workspace, and only changes its geometry in all-monitors mode.
- **FR-025** Every other window opened by the RDP client (popups, dialogs) MUST be kept on the
  same workspace as the main Windows window, in every mode, not on whichever workspace is focused.
- **FR-026** In all-monitors mode the main window MUST be floating and sized/positioned as in US3.1,
  and the remote desktop MUST follow the window size (dynamic resolution).
- **FR-019** Option 2 on ⇒ the Omarchy bar is hidden (with the stock `omarchy toggle bar`
  command) while the Windows window is open and restored afterwards, only if this feature
  was the one that hid it, on every exit path (normal close, failure, cancel, crash).
- **FR-005** Option 3 on ⇒ reveal a multi-select list of eligible disks; off ⇒ hide it
  and attach nothing.
- **FR-006** The list MUST be built from the disks present at the moment the dialog
  opens and MUST be refreshable without closing the dialog.
- **FR-007** System disks and the VM's own storage MUST NEVER be listed or attachable.
- **FR-008** A selected disk that is mounted on the host MUST NOT be attached until the
  user has seen and accepted the unmount.
- **FR-009** Selected disks MUST be attached read/write to the VM for that session only;
  nothing about them is persisted beyond the session.
- **FR-010** Disks MUST be released back to the host when the VM stops, including after a
  failed or aborted launch.
- **FR-011** A progress window MUST be shown from **Start** until the Windows window
  appears, reporting the stages of US5 and an overall progress indicator.
- **FR-012** A shutdown window MUST be shown when the VM is being stopped by a closed
  window, reporting stopping and finished states.
- **FR-013** Both windows MUST use the shell's existing theme and components and MUST NOT
  require installing anything (Constitution I, IV).
- **FR-014** On any failure the project MUST leave either "VM running and reported" or
  "VM stopped, disks released, and reported"; never an unreported half state.
- **FR-015** A second launch attempt while one is already in progress MUST NOT start a
  second session; it brings the existing progress window forward instead.
- **FR-016** Authorization declined at any privilege prompt MUST abort cleanly with the
  reason shown.
- **FR-020** Releasing disks MUST happen in this order, with no step skipped: request a normal
  guest shutdown → wait until the VM is confirmed stopped → release the disks → restore automount.
- **FR-021** While disks are attached, a host shutdown or reboot MUST NOT cut this sequence short
  if the system can wait: the guest shutdown starts at once and the host shutdown is held for as
  long as the system allows.
- **FR-022** Every launch MUST begin with a reconciliation step, before the dialog's choices take
  effect: detect leftovers of an earlier session (running container, attached or half-attached disks,
  paused automount, hidden bar), repair them, and report what was repaired. A session that cannot be
  reconciled MUST stop the launch with a clear message rather than attach more disks on top of it.
- **FR-023** If a disk could not be released cleanly (guest forced off, host went down first), the
  next launch MUST report it and MUST NOT auto-repair or auto-mount it read/write on the host.
- **FR-017** Installing the feature MUST be reversible with one command that restores the
  stock launcher entry and removes everything else it added.
- **FR-018** The existing `omarchy windows vm …` commands MUST keep working unchanged,
  whether or not this feature is installed.

## 4. Non-functional requirements

- **NFR-001** The dialog appears within 500 ms of launching (shell already running).
- **NFR-002** Progress text refreshes at least once per second while booting.
- **NFR-003** No credential (VM password) is ever written to a log, a status file, a
  notification or the progress window.
- **NFR-004** Survives `omarchy update` without manual reapplication, or, where a
  re-assert is unavoidable, does it automatically at shell start.
- **NFR-005** UI strings are in English; they live in one place so a Spanish translation
  can be added later.

## 5. Edge cases

- The user has Docker without sudo (docker group): no authorization stage appears; the
  stage list adapts.
- The VM is already running when Start is pressed with option 3 on and disks
  selected: disks cannot be added to a running VM safely, so a message explains the
  situation and asks the user to choose **Restart the VM with these disks** (anything
  unsaved in Windows is lost, and the message says so) or **Continue without these
  disks**. There is no default; **Cancel** aborts the launch with no changes.
- A selected disk is unplugged while Windows is booting: report it, continue the launch
  without it, do not hang.
- Windows never reports ready (2-minute limit today): progress window shows the timeout,
  offers Retry and Close; the VM is stopped or reported per FR-014.
- The RDP client crashes instead of being closed normally: treated as "window closed",
  honouring option 1.
- Dialog launched from a TTY/SSH with no shell running: falls back to the stock launcher
  behaviour with a clear message rather than failing silently.
- The user shuts down or reboots while the VM runs with **no disks** attached and option 1 off: no
  change from today (Docker stops the container normally).
- Power loss or a hard kill while disks are attached: cannot be prevented; handled by FR-022/FR-023
  at the next launch.

## 6. Out of scope

- Remembering last choices between sessions: the dialog always starts from the defaults (C3).
- Creating or reconfiguring the VM (RAM, CPU, disk size) — stays in `omarchy windows vm install`.
- USB device passthrough (keyboards, webcams, sticks as USB devices). Only block-disk
  attachment is covered here.
- Snapshots, multiple VMs, non-Omarchy hosts.

## 7. Resolved questions

- **C1 — Which disks are "external"?** Removable volumes (USB sticks and similar) plus storage
  units that are not part of the Linux system. A disk holding `/`, `/boot`, `/home`, swap or the
  VM's own storage is never eligible (FR-007).
- **C2 — Selection unit.** Whole disk. Windows needs the partition table to recognise volumes;
  partitions are shown as descriptive text only.
- **C3 — Remembering choices.** No. The dialog always starts from the stated defaults.
- **C4 — "All monitors".** One window spanning all connected monitors, with the Omarchy bar hidden
  while it is open (FR-004, FR-019).
- **C5 — VM already running with disks selected.** Explain the situation and let the user choose
  restart-with-disks or continue-without; no default (see §5).

## 8. Acceptance checklist

- [ ] Every user scenario above has an automated or scripted manual test in `tasks.md`.
- [x] No `[NEEDS CLARIFICATION]` marker remains.
- [ ] The constitution check in `plan.md` passes or documents each justified exception.
