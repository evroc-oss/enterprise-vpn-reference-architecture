#!/usr/bin/env bash
# 04-setup-ipsec.sh -- stand up the IPSec tunnel between the two deployed
# sides. This is the "prep for IPSec" step: it is the first moment BOTH
# peers' public IPs are known, so it also owns the tunnel's SG rules.
#
#   1. AGREE on the secret   : secrets/ipsec.psk (from 01-generate-secrets.sh;
#                              only read here, never regenerated)
#   2. ADD the tunnel SG
#      rules (now that we
#      know the answers)    : allow-ike-from-peer (UDP/500) and
#                             allow-natt-from-peer (UDP/4500) on both gateway
#                             SGs, scoped to the peer's public IP /32. These
#                             rules are NOT created by 02/03 -- a lone side
#                             does not know its peer yet.
#   3. PROVISION the config  : templates/ipsec.conf.tpl rendered per side
#                              (responder first, then initiator) and pushed
#                              over SSH to /etc/ipsec.conf + /etc/ipsec.secrets.
#                              Gateways accept SSH from their subnet only, so
#                              provisioning goes through the respective
#                              jumphost. strongSwan is already installed but
#                              unconfigured (gateway cloud-init).
#   4. INITIALISE from the
#      enterprise ("A") side : the initiator (auto=start) is provisioned and
#                              restarted last, so the enterprise-datacenter
#                              gateway always brings the tunnel up. The evroc
#                              side is auto=add (responder only): both sides
#                              initiating at once creates duplicate IKE SAs
#                              that blackhole traffic.
#   5. WAIT for exactly one IKE SA + child SA per side.
#
# Requires: 01, 02 (evroc-cloud side), 03 (enterprise-datacenter side).
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
require_project

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -s secrets/ipsec.psk ]]    || die "run 01-generate-secrets.sh first (missing secrets/ipsec.psk)"
EDC_GW_PUBLIC_IP=$(env_get EDC_GW_PUBLIC_IP)     || die "run 03-deploy-enterprise-datacenter.sh first"
EC_GW_PUBLIC_IP=$(env_get EC_GW_PUBLIC_IP)       || die "run 02-deploy-evroc-cloud.sh first"
EDC_GW_PRIVATE_IP=$(env_get EDC_GW_PRIVATE_IP)   || die "run 03-deploy-enterprise-datacenter.sh first"
EC_GW_PRIVATE_IP=$(env_get EC_GW_PRIVATE_IP)     || die "run 02-deploy-evroc-cloud.sh first"
EDC_JUMPHOST_PUBLIC_IP=$(env_get EDC_JUMPHOST_PUBLIC_IP) || die "run 03-deploy-enterprise-datacenter.sh first"
EC_JUMPHOST_PUBLIC_IP=$(env_get EC_JUMPHOST_PUBLIC_IP)   || die "run 02-deploy-evroc-cloud.sh first"
PSK="$(cat secrets/ipsec.psk)"

# gateways allow SSH from the subnet only -> reach them via their jumphost
edc_gw() { vm_ssh_via "$EDC_JUMPHOST_PUBLIC_IP" "$EDC_GW_PRIVATE_IP" "$@"; }
ec_gw()  { vm_ssh_via "$EC_JUMPHOST_PUBLIC_IP" "$EC_GW_PRIVATE_IP" "$@"; }

say "1. agreed secret: secrets/ipsec.psk"

say "2. add IKE/NAT-T rules, scoped to the actual peer (02/03 never create these)"
scope_peer_rules() { # <sg> <peer-public-ip>
  local sg=$1 peer=$2 name
  for name in allow-ike-from-peer allow-natt-from-peer; do
    evroc networking securitygroup removerule "$sg" --name "$name" >/dev/null 2>&1 || true
  done
  ensure_rule "$sg" allow-ike-from-peer  Ingress UDP 500  "$peer/32"
  ensure_rule "$sg" allow-natt-from-peer Ingress UDP 4500 "$peer/32"
}
scope_peer_rules enterprise-datacenter-sg "$EC_GW_PUBLIC_IP"
scope_peer_rules evroc-cloud-sg          "$EDC_GW_PUBLIC_IP"
pass "IKE/NAT-T scoped to peers: enterprise->${EC_GW_PUBLIC_IP}/32, evroc->${EDC_GW_PUBLIC_IP}/32"

say "3. render ipsec.conf per side (responder 'add', initiator 'start')"
# --- responder: evroc-cloud-gateway ---
export LEFT_PUBLIC_IP="$EC_GW_PUBLIC_IP" PEER_PUBLIC_IP="$EDC_GW_PUBLIC_IP" \
       LEFT_SUBNET=10.0.11.0/24 RIGHT_SUBNET=10.0.10.0/24 AUTO=add
render templates/ipsec.conf.tpl cloud-init/ipsec.evroc-cloud.conf

# --- initiator: enterprise-datacenter-gateway ---
export LEFT_PUBLIC_IP="$EDC_GW_PUBLIC_IP" PEER_PUBLIC_IP="$EC_GW_PUBLIC_IP" \
       LEFT_SUBNET=10.0.10.0/24 RIGHT_SUBNET=10.0.11.0/24 AUTO=start
render templates/ipsec.conf.tpl cloud-init/ipsec.enterprise-datacenter.conf

push_ipsec_to() { # <jumphost-pubip> <gw-private-ip> <conf-file> <left-pub> <peer-pub>
  local jumphost=$1 gwip=$2 conf=$3 leftid=$4 peerid=$5
  say "provision gateway $gwip (via jumphost) with $(basename "$conf")"
  vm_ssh_via "$jumphost" "$gwip" 'sudo tee /etc/ipsec.conf >/dev/null' < "$conf"
  printf '%s %s : PSK "%s"\n' "$leftid" "$peerid" "$PSK" \
    | vm_ssh_via "$jumphost" "$gwip" 'sudo tee /etc/ipsec.secrets >/dev/null'
  vm_ssh_via "$jumphost" "$gwip" 'sudo chmod 600 /etc/ipsec.secrets && sudo systemctl restart strongswan-starter'
}

# responder first, initiator last -> the tunnel is initialised from the A side
push_ipsec_to "$EC_JUMPHOST_PUBLIC_IP"  "$EC_GW_PRIVATE_IP"  cloud-init/ipsec.evroc-cloud.conf           "$EC_GW_PUBLIC_IP"  "$EDC_GW_PUBLIC_IP"
push_ipsec_to "$EDC_JUMPHOST_PUBLIC_IP" "$EDC_GW_PRIVATE_IP" cloud-init/ipsec.enterprise-datacenter.conf "$EDC_GW_PUBLIC_IP" "$EC_GW_PUBLIC_IP"

say "4/5. wait for the tunnel (up to ~10 min; first boot runs cloud-init apt)"
tunnel_installed() { # <jumphost-pubip> <gw-private-ip>
  vm_ssh_via "$1" "$2" 'sudo ipsec statusall' 2>/dev/null | grep -q "INSTALLED, TUNNEL"; }
for _ in $(seq 1 60); do
  if tunnel_installed "$EDC_JUMPHOST_PUBLIC_IP" "$EDC_GW_PRIVATE_IP" \
     && tunnel_installed "$EC_JUMPHOST_PUBLIC_IP" "$EC_GW_PRIVATE_IP"; then
    edc_gw 'sudo ipsec statusall | grep -E "ESTABLISHED|INSTALLED"' | sed 's/^/  edc /'
    ec_gw  'sudo ipsec statusall | grep -E "ESTABLISHED|INSTALLED"' | sed 's/^/  ec  /'
    n_edc=$(edc_gw 'sudo ipsec statusall' | grep -c ESTABLISHED)
    n_ec=$(ec_gw  'sudo ipsec statusall' | grep -c ESTABLISHED)
    [[ "$n_edc" == 1 && "$n_ec" == 1 ]] \
      && pass "tunnel up, exactly one IKE SA per side" \
      || fail "$n_edc/$n_ec ESTABLISHED (expect 1/1) -- both sides initiated?"
    exit 0
  fi
  sleep 10
done
fail "tunnel did not come up -- inspect via the jumphost: ssh edc-gateway 'sudo journalctl -u strongswan-starter -n 50'"
