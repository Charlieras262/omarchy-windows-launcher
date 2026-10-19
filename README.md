# Omarchy Windows Launcher

A pre-launch dialog and progress windows for the [Omarchy](https://omarchy.org) Windows VM.
Before the VM opens it asks:

1. **Close the VM when the window is closed** (on by default)
2. **Use all monitors** (off by default)
3. **Mount external disks** (off by default) — pick the disks to hand to Windows from a list

and it shows a native progress window while the VM boots and another while it shuts down.
It is built only from what Omarchy already ships (the Omarchy shell, bash, `xfreerdp3`, Docker)
— nothing extra to install — and it never edits files owned by Omarchy.

## Status

**Early development.** Options 1 and 2 (close-on-exit, all monitors) and the progress windows are implemented and
unit-tested; external disks are not built yet. This project follows spec-driven development:

| Document | Purpose |
|---|---|
| [`.specify/memory/constitution.md`](.specify/memory/constitution.md) | Principles every decision must respect |
| [`specs/001-pre-launch-dialog/spec.md`](specs/001-pre-launch-dialog/spec.md) | What and why (technology-free) |
| [`specs/001-pre-launch-dialog/plan.md`](specs/001-pre-launch-dialog/plan.md) | How: architecture and decisions |
| [`specs/001-pre-launch-dialog/tasks.md`](specs/001-pre-launch-dialog/tasks.md) | Ordered, traceable work items |

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

## Try it

```bash
./install.sh      # user-level only: plugin, launcher, desktop entry (your existing launch command is kept)
./uninstall.sh    # restores the previous desktop entry and removes everything
bash tests/run.sh # unit tests (fakes only, never touches the real VM)
```
