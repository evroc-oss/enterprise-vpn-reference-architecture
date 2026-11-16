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
#   6. TIGHTEN the evroc-cloud egress. 02 deploys that side with full egress
#      because its gateway needs cloud-init apt for strongswan-starter; this
#      is the first place both peer public IPs are known, and once the tunnel
#      is verified up that cloud-init has long finished. Full egress is
#      replaced with the minimal policy (internal 10/8, link-local, public
#      DNS, NTP; gateway SG additionally IKE/NAT-T to the EDC peer). This
#      protection lives HERE -- not in the optional 03 -- so it applies even
#      when a real enterprise gateway replaces the simulated side.
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
tunnel_up=0
for _ in $(seq 1 60); do
  if tunnel_installed "$EDC_JUMPHOST_PUBLIC_IP" "$EDC_GW_PRIVATE_IP" \
     && tunnel_installed "$EC_JUMPHOST_PUBLIC_IP" "$EC_GW_PRIVATE_IP"; then
    edc_gw 'sudo ipsec statusall | grep -E "ESTABLISHED|INSTALLED"' | sed 's/^/  edc /'
    ec_gw  'sudo ipsec statusall | grep -E "ESTABLISHED|INSTALLED"' | sed 's/^/  ec  /'
    n_edc=$(edc_gw 'sudo ipsec statusall' | grep -c ESTABLISHED)
    n_ec=$(ec_gw 'sudo ipsec statusall' | grep -c ESTABLISHED)
    if [[ "$n_edc" == 1 && "$n_ec" == 1 ]]; then
      pass "tunnel up, exactly one IKE SA per side"
      tunnel_up=1
    else
      fail "$n_edc/$n_ec ESTABLISHED (expect 1/1) -- both sides initiated?"
    fi
    break
  fi
  sleep 10
done
[[ "$tunnel_up" == 1 ]] \
  || fail "tunnel did not come up -- inspect via the jumphost: ssh edc-gateway 'sudo journalctl -u strongswan-starter -n 50'"

say "6. tighten evroc-cloud egress to the minimal policy"
# 02 deploys the evroc side with full egress because its gateway installs
# strongswan-starter via cloud-init apt (jumphost/app-vm templates install
# no packages). The tunnel being up proves that cloud-init finished, and no
# EC-side flow needs general internet egress any more:
#   * internal 10/8 covers intra-subnet + both tunnel subnets, so jumphost->
#     VM SSH, forwarded tunnel traffic and 05-verify all keep working
#   * link-local covers the platform's DHCP-provided services (including
#     its DNS resolver); 8.8.8.8/8.8.4.4 cover public DNS
#   * NTP is UDP/123 to anywhere (timesyncd's ntp.ubuntu.com resolves to
#     varying IPs)
for sg in evroc-cloud-sg evroc-cloud-jumphost-sg; do
  evroc networking securitygroup removerule "$sg" --name=allow-egress >/dev/null 2>&1 || true
  ensure_rule "$sg" allow-egress-internal      Egress All "" 10.0.0.0/8
  ensure_rule "$sg" allow-egress-linklocal     Egress All "" 169.254.0.0/16
  ensure_rule "$sg" allow-egress-dns-primary   Egress All "" 8.8.8.8/32
  ensure_rule "$sg" allow-egress-dns-secondary Egress All "" 8.8.4.4/32
  ensure_rule "$sg" allow-egress-ntp           Egress UDP 123 0.0.0.0/0
done
# Gateway SG only: IKE/NAT-T egress to the actual EDC peer (remove+re-add so
# a changed peer IP updates the rules, same pattern as the ingress rules in
# step 2). Needed for EC->EDC flows re-encapsulated towards the peer and for
# re-initiation from this responder (dpdaction=restart); ordinary IKE
# replies are stateful returns.
for name in allow-egress-ike-to-peer allow-egress-natt-to-peer; do
  evroc networking securitygroup removerule evroc-cloud-sg --name "$name" >/dev/null 2>&1 || true
done
ensure_rule evroc-cloud-sg allow-egress-ike-to-peer  Egress UDP 500  "$EDC_GW_PUBLIC_IP/32"
ensure_rule evroc-cloud-sg allow-egress-natt-to-peer Egress UDP 4500 "$EDC_GW_PUBLIC_IP/32"
pass "evroc-cloud egress: 10/8 + link-local + DNS (8.8.8.8, 8.8.4.4) + NTP; gateway also UDP 500/4500 -> $EDC_GW_PUBLIC_IP"
