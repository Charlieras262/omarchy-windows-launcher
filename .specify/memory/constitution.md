# Omarchy Windows Launcher — Constitution

Principles that every spec, plan and task in this repository must respect.
A plan that violates one of them must say so explicitly and justify it.

## I. No new dependencies

The launcher is built only from what a stock Omarchy install already ships:
the Omarchy shell (Quickshell/QML and its `Ui/` primitives), bash, `xfreerdp3`,
`docker`, `lsblk`, `udisksctl`, `jq`, `hyprctl` and polkit. Installing an extra
package, toolkit or runtime (GTK/Qt apps, Electron, Python/Node services, zenity,
yad, …) is out of bounds.

## II. Never modify what the system owns

Nothing under `/usr/share/omarchy/` or `/usr/bin/omarchy-*` is edited, patched or
replaced. The root-owned `/var/lib/omarchy/windows/docker-compose.yml` is never
edited in place either. Behaviour is layered on top (a user plugin, a wrapper
command, an additional compose override) so that `omarchy update` cannot undo it
and removing the project restores stock behaviour exactly.

## III. Least privilege, validated input

Omarchy deliberately gates Docker behind a polkit prompt because Docker access is
root-equivalent. This project must not widen that hole. Anything that runs as root:

- lives in a root-owned, non-user-writable path installed once with `sudo`;
- accepts only closed-set, validated arguments (device paths must come from a
  fresh `lsblk` scan, never from free text);
- never reads a compose file, script or path the unprivileged user could rewrite.

## IV. Native look and behaviour

User-facing windows are Omarchy shell plugins using the shell's own theme
singleton and `Ui/` components (`Toggle`, `MultiSelect`, `Button`, …). They follow
the active theme, run inside the already-running shell process, and are
keyboard-operable.

## V. Safe by default, destructive only on purpose

Defaults favour not losing data: external disks are never attached unless the
user ticks them, system disks can never be offered, a disk still mounted on the
host is never handed to the VM without an explicit, visible unmount step, and a
failed start never leaves a disk half-attached.

## VI. Fail visible, fail clean

Every failure (authorization declined, Docker down, boot timeout, RDP crash)
produces a clear message in the progress window and leaves the machine in a known
state: container either running and reported, or stopped and reported. No silent
background leftovers.

## VII. Spec-driven

Behaviour is defined in `specs/NNN-*/spec.md` (what and why, technology-free),
designed in `plan.md` (how), and executed through `tasks.md`. Code is not written
for a requirement that is not in a spec; ambiguities are marked
`[NEEDS CLARIFICATION]` and resolved before the plan is considered final.
