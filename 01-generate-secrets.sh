#!/usr/bin/env bash
# 01-generate-secrets.sh -- create the two secrets the reference architecture needs:
#   * secrets/admin_ed25519[.pub] : SSH admin keypair, injected into every VM
#     via cloud-init (with custom user-data the platform does NOT inject
#     --ssh-authorized-key style keys; the cloud user is "ubuntu")
#   * secrets/ipsec.psk          : the pre-shared key for the IKEv2 tunnel.
#     This file is the "agreed secret" between the two sides -- provisioning
#     happens later in 04-setup-ipsec.sh.
# Idempotent: existing files are never overwritten (a re-agreed PSK would
# invalidate a running tunnel and lose nothing here).
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

mkdir -p secrets

if [[ ! -f secrets/admin_ed25519 ]]; then
  say "generate admin ssh keypair (secrets/admin_ed25519)"
  umask 077
  ssh-keygen -q -t ed25519 -N '' -C 'enterprise-vpn-admin' -f secrets/admin_ed25519
else
  say "admin ssh keypair already exists -- keeping it"
fi
chmod 600 secrets/admin_ed25519

if [[ ! -s secrets/ipsec.psk ]]; then
  say "generate ipsec pre-shared key (secrets/ipsec.psk)"
  umask 077
  openssl rand -base64 32 > secrets/ipsec.psk
else
  say "ipsec psk already exists -- keeping it (it is the agreed secret)"
fi
chmod 600 secrets/ipsec.psk

say "secrets in place:"
ls -l secrets/
