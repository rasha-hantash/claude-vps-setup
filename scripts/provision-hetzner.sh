#!/usr/bin/env bash
# Provisions a Hetzner Cloud VM. Idempotent: if a VM with $VM_NAME already exists, prints its IP and exits 0.
#
# Required env:
#   HCLOUD_TOKEN   Hetzner API token with Read & Write scope
#   VM_NAME        Name to assign the VM
#   VM_LOCATION    e.g. nbg1, fsn1, hel1, ash, hil, sin
#   VM_TYPE        e.g. cx23, cx33, cpx22
#   SSH_KEY_PATH   Path to a public SSH key file on this machine
#
# Prints the VM's public IPv4 on the last line of stdout.

set -euo pipefail

: "${HCLOUD_TOKEN:?HCLOUD_TOKEN is required}"
: "${VM_NAME:?VM_NAME is required}"
: "${VM_LOCATION:?VM_LOCATION is required}"
: "${VM_TYPE:?VM_TYPE is required}"
: "${SSH_KEY_PATH:?SSH_KEY_PATH is required}"

if ! command -v hcloud >/dev/null 2>&1; then
  echo "hcloud CLI not found. Install via: brew install hcloud" >&2
  exit 1
fi

if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "SSH key not found at $SSH_KEY_PATH" >&2
  exit 1
fi

export HCLOUD_TOKEN

# If VM already exists, just print its IP.
if hcloud server describe "$VM_NAME" >/dev/null 2>&1; then
  echo "VM '$VM_NAME' already exists, reusing." >&2
  hcloud server ip "$VM_NAME"
  exit 0
fi

# Register the SSH key under a deterministic name derived from its fingerprint, so re-runs don't pile up duplicates.
KEY_FINGERPRINT=$(ssh-keygen -lf "$SSH_KEY_PATH" | awk '{print $2}' | sed 's|^SHA256:||' | tr -d '/+=' | cut -c1-12)
KEY_NAME="claude-vps-setup-${KEY_FINGERPRINT}"

if ! hcloud ssh-key describe "$KEY_NAME" >/dev/null 2>&1; then
  echo "Registering SSH key as '$KEY_NAME'..." >&2
  hcloud ssh-key create --name "$KEY_NAME" --public-key-from-file "$SSH_KEY_PATH" >&2
fi

echo "Creating VM '$VM_NAME' (type=$VM_TYPE, location=$VM_LOCATION)..." >&2
hcloud server create \
  --name "$VM_NAME" \
  --type "$VM_TYPE" \
  --location "$VM_LOCATION" \
  --image ubuntu-24.04 \
  --ssh-key "$KEY_NAME" \
  >&2

# Print the public IPv4 as the last line.
hcloud server ip "$VM_NAME"
