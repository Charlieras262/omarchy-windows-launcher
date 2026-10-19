#!/bin/bash
# Spec FR-005..FR-007 (plan D4): which disks may be offered to the VM.
cd "$(dirname "$0")/.." || exit 1
source tests/lib.sh
source lib/disks.sh

paths() { jq -r '[.[].path] | join(" ")'; }

echo "disk eligibility: this machine"
export OWL_LSBLK_JSON=tests/fixtures/this-machine.json
export OWL_PROTECTED_DISKS=""
assert_eq "offers data disks and the USB stick, nothing else" \
  "/dev/sda /dev/sdb /dev/sdc" "$(owl_list_disks | paths)"
assert_eq "root NVMe (LUKS/btrfs stack) is never offered" \
  "0" "$(owl_list_disks | jq '[.[] | select(.path == "/dev/nvme0n1")] | length')"
assert_eq "zram swap is never offered" \
  "0" "$(owl_list_disks | jq '[.[] | select(.name | startswith("zram"))] | length')"
assert_eq "USB stick is flagged removable" \
  "true" "$(owl_list_disks | jq '.[] | select(.path == "/dev/sdc") | .removable')"
assert_eq "internal SATA disk is not flagged removable" \
  "false" "$(owl_list_disks | jq '.[] | select(.path == "/dev/sda") | .removable')"
assert_eq "partitions are listed as description with their mounts" \
  "Windows USB UEFI_NTFS" "$(owl_list_disks | jq -r '.[] | select(.path == "/dev/sdc") | [.partitions[] | .label] | join(" ")')"
assert_eq "summary line is human readable" \
  "DataTraveler 70 · 61.9 GB · removable · Windows USB (ntfs), UEFI_NTFS (vfat)" \
  "$(owl_list_disks | jq -c '.[] | select(.path == "/dev/sdc")' | owl_disk_summary)"

echo "disk eligibility: edge cases"
export OWL_LSBLK_JSON=tests/fixtures/edge-cases.json
assert_eq "no-media reader, loop, optical, /var/*, swap are excluded; VM disk offered when not protected" \
  "/dev/sde /dev/sdh" "$(owl_list_disks | paths)"
export OWL_PROTECTED_DISKS="/dev/sdh"
assert_eq "a disk backing the VM storage is excluded" \
  "/dev/sde" "$(owl_list_disks | paths)"
assert_eq "model whitespace is trimmed" \
  "External HDD" "$(owl_list_disks | jq -r '.[0].model')"
assert_eq "USB disk without rm/hotplug flags is still removable via tran=usb" \
  "true" "$(owl_list_disks | jq '.[0].removable')"

echo "disk eligibility: empty and malformed input"
empty=$(mktemp)
echo '{"blockdevices":[]}' > "$empty"
export OWL_LSBLK_JSON=$empty
assert_eq "no disks gives an empty list" "[]" "$(owl_list_disks | jq -c .)"
rm -f "$empty"
export OWL_LSBLK_JSON=/nonexistent
owl_list_disks >/dev/null 2>&1
assert_eq "missing input fails instead of offering something" "1" "$?"

finish
