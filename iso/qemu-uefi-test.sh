#!/usr/bin/env bash
# Manual end-to-end test harness. It always uses a new qcow2 disk image and
# never exposes a host block device to QEMU.
set -Eeuo pipefail

ISO_FILE=${1:-}
[ -n "$ISO_FILE" ] || { echo "Usage: $0 <installer.iso>" >&2; exit 2; }
[ -f "$ISO_FILE" ] || { echo "ISO not found: $ISO_FILE" >&2; exit 2; }
command -v qemu-system-x86_64 >/dev/null || { echo 'qemu-system-x86_64 is required' >&2; exit 1; }
command -v qemu-img >/dev/null || { echo 'qemu-img is required' >&2; exit 1; }

find_ovmf() {
  local code_candidate vars_candidate
  for code_candidate in \
    /usr/share/edk2/x64/OVMF_CODE.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
    vars_candidate="$(dirname "$code_candidate")/OVMF_VARS.fd"
    [ -r "$code_candidate" ] && [ -r "$vars_candidate" ] && {
      printf '%s:%s\n' "$code_candidate" "$vars_candidate"
      return 0
    }
  done
  return 1
}

OVMF_PAIR=$(find_ovmf) || {
  echo 'UEFI firmware was not found. Install an OVMF/edk2 package and retry.' >&2
  exit 1
}
OVMF_CODE=${OVMF_PAIR%%:*}
OVMF_VARS=${OVMF_PAIR#*:}
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kiosk-qemu.XXXXXX")
DISK="$TEST_DIR/kiosk-target.qcow2"
VARS="$TEST_DIR/OVMF_VARS.fd"
cp "$OVMF_VARS" "$VARS"
qemu-img create -f qcow2 "$DISK" 24G >/dev/null

cat <<EOF
Launching UEFI test VM with an empty 24 GiB virtual disk:
  $DISK

Press Enter for the single installation action in the VM. At the final screen,
use the QEMU monitor (Ctrl+Alt+2) to eject the ISO:
  change ide1-cd0 /dev/null
Then return to the display (Ctrl+Alt+1) and press Enter to restart. The VM must
boot from the virtual disk directly into Offline Kiosk.
EOF

QEMU_KVM=()
[ -r /dev/kvm ] && QEMU_KVM=(-enable-kvm)
qemu-system-x86_64 "${QEMU_KVM[@]}" \
  -machine q35 -m 4096 -smp 2 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$VARS" \
  -drive if=virtio,format=qcow2,file="$DISK" \
  -drive if=ide,media=cdrom,readonly=on,file="$ISO_FILE" \
  -boot order=d -monitor stdio
