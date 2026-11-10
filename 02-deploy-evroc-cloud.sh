#!/usr/bin/env bash
# 02-deploy-evroc-cloud.sh -- deploy the "B" / evroc-cloud side, self-contained.
#
# Creates (idempotently):
#   vpc       evroc-cloud-vpc                10.0.11.0/24 (exactly one /24)
#   subnet    evroc-cloud-subnet-beta        10.0.11.0/24  zone a (gateways, jumphost, app, kubeAPI)
#   sgs       evroc-cloud-sg, evroc-cloud-jumphost-sg
#   pubips    evroc-cloud-gateway-pubip, evroc-cloud-jumphost-pubip
#   disks     one per VM (ubuntu.24-04.1, 20GB)
#   VMs       evroc-cloud-gateway   10.0.11.x  public IP  (strongSwan, tunnel RESPONDER;
#                                                         ipsec config pushed later by 04)
#             evroc-cloud-jumphost  10.0.11.x  public IP  (admin access, no services)
#             evroc-cloud-app-vm   10.0.11.x  NO public IP (example app :8080, source-IP echo)
#
# SSH exposure policy:
#   * everything except the jump host: SSH from the subnet only
#   * the jump host: SSH from $ALLOW_SSH_CIDR_RANGE (export it at deploy
#     time, e.g. `ALLOW_SSH_CIDR_RANGE=194.14.80.0/24 ./02-deploy...`;
#     defaults to 0.0.0.0/0 = wide open, with a warning)
# The tunnel IKE/NAT-T rules are NOT created here -- the enterprise peer's
# public IP is only known once both sides exist; 04-setup-ipsec.sh adds them
# scoped to the actual peer.
#
# The route back to the enterprise subnet (10.0.10.0/24 via the gateway) is
# installed here already -- that CIDR is an agreed design constant of the
# VPN, so the B side can be deployed before (or without) the A side.
#
# Records actual allocated IPs into resources.env and re-renders
# ssh-config-snippet. Requires: 01-generate-secrets.sh.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
require_project

[[ -f secrets/admin_ed25519.pub ]] || die "run 01-generate-secrets.sh first"
export SSH_PUBKEY="$(cat secrets/admin_ed25519.pub)"

ALLOW_SSH_CIDR_RANGE="${ALLOW_SSH_CIDR_RANGE:-0.0.0.0/0}"
env_set ALLOW_SSH_CIDR_RANGE "$ALLOW_SSH_CIDR_RANGE"
say "jumphost SSH will be reachable from: $ALLOW_SSH_CIDR_RANGE"
[[ "$ALLOW_SSH_CIDR_RANGE" == "0.0.0.0/0" ]] && echo "  (WARNING: default wide-open; export ALLOW_SSH_CIDR_RANGE=<cidr> to restrict)"

say "== evroc-cloud: vpc + subnets =="
ensure_vpc evroc-cloud-vpc 10.0.11.0/24
ensure_subnet evroc-cloud-subnet-beta  evroc-cloud-vpc 10.0.11.0/24 a

say "== evroc-cloud: public IPs =="
ensure_pubip evroc-cloud-gateway-pubip
ensure_pubip evroc-cloud-jumphost-pubip
EC_GW_PUBLIC_IP=$(wait_pubip evroc-cloud-gateway-pubip);      env_set EC_GW_PUBLIC_IP "$EC_GW_PUBLIC_IP"
EC_JUMPHOST_PUBLIC_IP=$(wait_pubip evroc-cloud-jumphost-pubip); env_set EC_JUMPHOST_PUBLIC_IP "$EC_JUMPHOST_PUBLIC_IP"
echo "evroc-cloud-gateway-pubip  -> $EC_GW_PUBLIC_IP"
echo "evroc-cloud-jumphost-pubip -> $EC_JUMPHOST_PUBLIC_IP"

say "== evroc-cloud: security groups =="
# gateway SG: SSH from the subnet only (admins come in via the jumphost),
# intra-beta, full egress. IKE/NAT-T rules arrive with 04-setup-ipsec.sh.
ensure_sg evroc-cloud-sg evroc-cloud-vpc
ensure_rule evroc-cloud-sg allow-egress Egress  All ""  0.0.0.0/0
ensure_rule evroc-cloud-sg allow-ssh    Ingress TCP 22  10.0.11.0/24
ensure_rule evroc-cloud-sg allow-intra Ingress All ""  10.0.11.0/24

# jumphost/app SG: SSH from the deploy-time allow-list, traffic from both
# example subnets, full egress. Remove+re-add so re-running with a different
# ALLOW_SSH_CIDR_RANGE updates the rule.
ensure_sg evroc-cloud-jumphost-sg evroc-cloud-vpc
ensure_rule evroc-cloud-jumphost-sg allow-egress   Egress  All ""  0.0.0.0/0
evroc networking securitygroup removerule evroc-cloud-jumphost-sg --name=allow-ssh >/dev/null 2>&1 || true
ensure_rule evroc-cloud-jumphost-sg allow-ssh      Ingress TCP 22 "$ALLOW_SSH_CIDR_RANGE"
ensure_rule evroc-cloud-jumphost-sg allow-intra    Ingress All ""  10.0.11.0/24
ensure_rule evroc-cloud-jumphost-sg allow-tunnel    Ingress All ""  10.0.10.0/24

say "== evroc-cloud: disks =="
ensure_disk evroc-cloud-gateway-disk
ensure_disk evroc-cloud-jumphost-disk
ensure_disk evroc-cloud-app-disk

say "== evroc-cloud: gateway VM (tunnel responder, stand-in kubeAPI :6443; ipsec config arrives via 04) =="
render templates/evroc-cloud-gateway.yaml.tpl cloud-init/evroc-cloud-gateway.yaml
ensure_vm evroc-cloud-gateway evroc-cloud-subnet-beta evroc-cloud-gateway-disk \
  evroc-cloud-sg evroc-cloud-gateway-pubip cloud-init/evroc-cloud-gateway.yaml
wait_vm_ready evroc-cloud-gateway
EC_GW_PRIVATE_IP=$(wait_vm_privateip evroc-cloud-gateway); env_set EC_GW_PRIVATE_IP "$EC_GW_PRIVATE_IP"
echo "evroc-cloud-gateway private IP: $EC_GW_PRIVATE_IP"

say "== evroc-cloud: jumphost VM (admin access only, no services) =="
export GW_PRIVATE_IP="$EC_GW_PRIVATE_IP"
render templates/evroc-cloud-host.yaml.tpl cloud-init/evroc-cloud-jumphost.yaml
ensure_vm evroc-cloud-jumphost evroc-cloud-subnet-beta evroc-cloud-jumphost-disk \
  evroc-cloud-jumphost-sg evroc-cloud-jumphost-pubip cloud-init/evroc-cloud-jumphost.yaml
wait_vm_ready evroc-cloud-jumphost
EC_JUMPHOST_PRIVATE_IP=$(wait_vm_privateip evroc-cloud-jumphost); env_set EC_JUMPHOST_PRIVATE_IP "$EC_JUMPHOST_PRIVATE_IP"
echo "evroc-cloud-jumphost private IP: $EC_JUMPHOST_PRIVATE_IP"

say "== evroc-cloud: app VM (NO public IP, example app :8080 embedded in cloud-init) =="
render templates/evroc-cloud-app-vm.yaml.tpl cloud-init/evroc-cloud-app-vm.yaml
ensure_vm evroc-cloud-app-vm evroc-cloud-subnet-beta evroc-cloud-app-disk \
  evroc-cloud-jumphost-sg "" cloud-init/evroc-cloud-app-vm.yaml
wait_vm_ready evroc-cloud-app-vm
EC_APP_PRIVATE_IP=$(wait_vm_privateip evroc-cloud-app-vm); env_set EC_APP_PRIVATE_IP "$EC_APP_PRIVATE_IP"
echo "evroc-cloud-app-vm private IP: $EC_APP_PRIVATE_IP"

./gen-ssh-config.sh
say "evroc-cloud side deployed. Next: 03-deploy-enterprise-datacenter.sh (optional A side), then 04-setup-ipsec.sh"
