#!/bin/bash
# Disk eligibility for the Windows VM (spec FR-005..FR-007, plan D4).
#
# A disk is eligible when it is a whole disk (never a partition, loop, zram or
# optical drive), has media, and nothing in its device tree is part of the Linux
# system. "Part of the system" means a mountpoint such as /, /boot, /home, /usr,
# /var, /etc, or swap anywhere in the disk's subtree (so a LUKS/dm stack on top
# of a partition is covered), or the disk backs the VM's own storage.
#
# This file is sourced by the orchestrator and by the root helper; keep it free
# of side effects at source time.

OWL_LSBLK_COLUMNS="NAME,PATH,TYPE,SIZE,MODEL,LABEL,FSTYPE,TRAN,RM,HOTPLUG,MOUNTPOINTS"

# jq program: reads lsblk -J output, takes $protected (array of /dev paths that
# must never be offered) and prints the eligible disks as a JSON array.
# shellcheck disable=SC2016
OWL_DISKS_JQ='
def mounts: [.. | objects | .mountpoints? // [] | .[] | select(. != null)];
def system_mount:
  test("^(/|/boot(/.*)?|/efi(/.*)?|/home(/.*)?|/usr(/.*)?|/var(/.*)?|/etc(/.*)?|/opt(/.*)?|/srv(/.*)?|/nix(/.*)?|\\[SWAP\\])$");
def partitions: [(.children // [])[] | select(.type == "part") | {
  name, path, size, fstype, label,
  mounts: ([.. | objects | .mountpoints? // [] | .[] | select(. != null)])
}];

[ .blockdevices[]
  | select(.type == "disk")
  | select((.name | test("^(zram|loop|ram|sr|fd)[0-9]*$")) | not)
  | select((.size // 0) > 0)
  | select((mounts | map(system_mount) | any) | not)
  | select(.path as $p | ($protected | index($p)) | not)
  | {
      path, name,
      model: (.model // "" | gsub("^ +| +$"; "")),
      size, tran,
      removable: ((.rm // false) or (.hotplug // false) or (.tran == "usb")),
      partitions: partitions,
      mounts: mounts
    }
] | sort_by(.path)
'

# Whole disk(s) backing a directory (used to protect the VM storage anchors).
# Prints one /dev path per line; prints nothing if it cannot tell.
owl_backing_disk() {
  local dir="$1" real src
  real=$(realpath -e -- "$dir" 2>/dev/null) || return 0
  src=$(findmnt -n -o SOURCE -T "$real" 2>/dev/null) || return 0
  src=${src%%\[*} # btrfs subvolumes show as /dev/x[/@]
  [[ -b $src ]] || return 0
  lsblk -s -n -l -o PATH,TYPE "$src" 2>/dev/null | awk '$2 == "disk" { print $1 }'
}

# Paths that must never be offered, one per line. OWL_PROTECTED_DISKS (space
# separated) replaces the live lookup; the tests use it.
owl_protected_disks() {
  if [[ -n ${OWL_PROTECTED_DISKS+x} ]]; then
    tr ' ' '\n' <<<"$OWL_PROTECTED_DISKS" | sed '/^$/d'
    return 0
  fi
  local d
  for d in "${HOME}/.windows" "${HOME}/Windows" /var/lib/omarchy/windows; do
    owl_backing_disk "$d"
  done | sort -u
}

# Eligible disks as a JSON array. OWL_LSBLK_JSON (a file) replaces the live
# lsblk call; the tests use it.
owl_list_disks() {
  local json protected
  if [[ -n ${OWL_LSBLK_JSON:-} ]]; then
    json=$(cat -- "$OWL_LSBLK_JSON") || return 1
  else
    json=$(lsblk -J -b -o "$OWL_LSBLK_COLUMNS") || return 1
  fi
  protected=$(owl_protected_disks | jq -R . | jq -s .) || return 1
  jq --argjson protected "$protected" "$OWL_DISKS_JQ" <<<"$json"
}

# One-line human description of a disk entry (stdin: a single disk object).
owl_disk_summary() {
  jq -r '
    def gb: (. / 1000000000 * 10 | floor) / 10;
    [ (.model | select(. != "")) // .name,
      "\(.size | gb) GB",
      (if .removable then "removable" else "internal" end),
      ([.partitions[] | (.label // .name) + (if .fstype then " (" + .fstype + ")" else "" end)] | join(", "))
    ] | map(select(. != "")) | join(" · ")'
}

# Disks as MultiSelect options for the dialog: [{value, label, description}].
# Stdin: the JSON array from owl_list_disks.
owl_disk_options() {
  jq -c '
    def gb: (. / 1000000000 * 10 | floor) / 10;
    [ .[] | {
        value: .path,
        label: (if .model != "" then .model else .name end),
        description: ("\(.size | gb) GB · " + (if .removable then "removable" else "internal" end)
                      + (if (.partitions | length) > 0
                         then " · " + ([.partitions[] | (.label // .name)] | join(", "))
                         else "" end))
      } ]'
}
