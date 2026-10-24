#!/bin/bash
# GPU discovery and the vendor checks on the GPU settings, against a fake PCI tree shaped like the reference host.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
PCI_ROOT=$SANDBOX/pci; mkdir -p "$SANDBOX/drivers"
dev() {   # address vendor device class driver
  mkdir -p "$PCI_ROOT/$1" "$SANDBOX/drivers/$5"
  echo "0x$2" > "$PCI_ROOT/$1/vendor"; echo "0x$3" > "$PCI_ROOT/$1/device"; echo "$4" > "$PCI_ROOT/$1/class"
  ln -s "$SANDBOX/drivers/$5" "$PCI_ROOT/$1/driver"; }
dev 0000:82:00.0 10de 2230 0x030000 nvidia          # RTX A6000
dev 0000:82:00.1 10de 1aef 0x040300 snd_hda_intel
dev 0000:c8:00.0 1002 7448 0x030000 amdgpu          # W7900 (compute)
dev 0000:c8:00.1 1002 ab30 0x040300 snd_hda_intel
dev 0000:03:00.0 1002 7422 0x030000 amdgpu          # W6400 (display only)
dev 0000:03:00.1 1002 ab28 0x040300 snd_hda_intel
dev 0000:ca:00.0 1a03 2000 0x030000 ast             # BMC display chip
dev 0000:01:00.0 144d a80a 0x010802 nvme            # not a GPU

discover_gpus
eq "${NV_BDFS[*]}" 0000:82:00.0 "NVIDIA GPUs:"
eq "${AMD_BDFS[*]}" 0000:c8:00.0 "AMD compute GPUs:"
eq "${OTHER_BDFS[*]}" 0000:03:00.0 "AMD display cards:"
eq "${IGNORED_BDFS[*]}" 0000:ca:00.0 "ignored:"
eq "$(slot_functions 0000:03:00.0 | paste -sd,)" 0000:03:00.0,0000:03:00.1 "functions of a slot:"

ok_ v_nv ""
ok_ v_nv 0000:82:00.0
no_ v_nv 0000:82:00.0,0000:c8:00.0        # the mistake made on the first real run
no_ v_nv 0000:c8:00.0
ok_ v_amd 0000:c8:00.0
no_ v_amd 0000:03:00.0                    # display card is not a compute GPU
no_ v_amd 0000:82:00.0
ok_ v_iso none
AMD_GPUS=0000:c8:00.0
ok_ v_iso 0000:03:00.0
no_ v_iso 0000:c8:00.0                    # in use and isolated at once
no_ v_iso 0000:ca:00.0                    # never isolate the BMC display
AMD_GPUS=""
ok_ v_iso 0000:03:00.0
no_ v_iso 0000:c8:00.0                    # empty AMD_GPUS means every compute GPU is used

# saved settings are checked before each run, and the message names the setting
HOST_IP=""; METALLB_RANGE=""; INSTALL_DIR=/data/oif; NVIDIA_GPUS=0000:82:00.0,0000:c8:00.0; ISOLATE_GPUS=0000:03:00.0
out=$( (config_validate) 2>&1 ); rc=$?
eq "$rc" 1 "invalid saved settings stop the run:"
echo "$out" | grep -q "NVIDIA_GPUS: 0000:c8:00.0 is not an NVIDIA GPU" || fail "message names the setting and the GPU: $out"
NVIDIA_GPUS=0000:82:00.0
( config_validate ) >/dev/null 2>&1 || fail "valid saved settings pass"
finish
