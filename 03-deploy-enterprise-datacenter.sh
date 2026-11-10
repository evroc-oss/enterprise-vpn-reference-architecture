#!/usr/bin/env bash
# 03-deploy-enterprise-datacenter.sh -- OPTIONAL: deploy the "A" /
# enterprise-datacenter side. In production this side is the customer's own
# network with its own VPN gateway; this script stands up an evroc-hosted
# simulation of it so the tunnel and private-IP access can be demonstrated
# end to end. Skip it if you are bringing a real enterprise gateway.
#
# Creates (idempotently):
#   vpc       enterprise-datacenter-vpc        10.0.10.0/24 (exactly /24 so it
#                                                       never eats 10.0.11.0/24)
#   subnet    enterprise-datacenter-subnet     10.0.10.0/24  zone a
#   sgs       enterprise-datacenter-sg, enterprise-datacenter-jumphost-sg
#   pubips    enterprise-datacenter-gateway-pubip, enterprise-datacenter-jumphost-pubip
#   disks     one per VM
#   VMs       enterprise-datacenter-gateway  10.0.10.x  public IP (strongSwan, tunnel
#                                                       INITIATOR; config pushed by 04)
#             enterprise-datacenter-jumphost 10.0.10.x  public IP (admin access)
#             enterprise-datacenter-vm       10.0.10.x  NO public IP (the "customer
#                                                       workload": routes to the evroc
#                                                       subnets via the gateway)
#
# SSH exposure policy (same as 02): subnet-only except the jump host, which
# allows from $ALLOW_SSH_CIDR_RANGE (export at deploy time). Tunnel IKE/NAT-T
# rules are added by 04-setup-ipsec.sh once both peers are known.
#
# Requires: 01-generate-secrets.sh (and 02 if you later want the tunnel).
# Records actual IPs into resources.env and re-renders ssh-config-snippet.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
require_project

[[ -f secrets/admin_ed25519.pub ]] || die "run 01-generate-secrets.sh first"
export SSH_PUBKEY="$(cat secrets/admin_ed25519.pub)"

ALLOW_SSH_CIDR_RANGE="${ALLOW_SSH_CIDR_RANGE:-0.0.0.0/0}"
env_set ALLOW_SSH_CIDR_RANGE "$ALLOW_SSH_CIDR_RANGE"
say "jumphost SSH will be reachable from: $ALLOW_SSH_CIDR_RANGE"
[[ "$ALLOW_SSH_CIDR_RANGE" == "0.0.0.0/0" ]] && echo "  (WARNING: default wide-open; export ALLOW_SSH_CIDR_RANGE=<cidr> to restrict)"

say "== enterprise-datacenter: vpc + subnet =="
ensure_vpc enterprise-datacenter-vpc 10.0.10.0/24
ensure_subnet enterprise-datacenter-subnet enterprise-datacenter-vpc 10.0.10.0/24 a

say "== enterprise-datacenter: public IPs =="
ensure_pubip enterprise-datacenter-gateway-pubip
ensure_pubip enterprise-datacenter-jumphost-pubip
EDC_GW_PUBLIC_IP=$(wait_pubip enterprise-datacenter-gateway-pubip);      env_set EDC_GW_PUBLIC_IP "$EDC_GW_PUBLIC_IP"
EDC_JUMPHOST_PUBLIC_IP=$(wait_pubip enterprise-datacenter-jumphost-pubip); env_set EDC_JUMPHOST_PUBLIC_IP "$EDC_JUMPHOST_PUBLIC_IP"
echo "enterprise-datacenter-gateway-pubip  -> $EDC_GW_PUBLIC_IP"
echo "enterprise-datacenter-jumphost-pubip -> $EDC_JUMPHOST_PUBLIC_IP"

say "== enterprise-datacenter: security groups =="
# gateway/workload SG: SSH from the subnet only (admins come in via the
# jumphost), intra + tunnel traffic, full egress. IKE/NAT-T rules arrive
# with 04-setup-ipsec.sh.
ensure_sg enterprise-datacenter-sg enterprise-datacenter-vpc
ensure_rule enterprise-datacenter-sg allow-egress Egress  All ""  0.0.0.0/0
ensure_rule enterprise-datacenter-sg allow-ssh    Ingress TCP 22  10.0.10.0/24
ensure_rule enterprise-datacenter-sg allow-intra  Ingress All ""  10.0.10.0/24
ensure_rule enterprise-datacenter-sg allow-remote-vpc Ingress All ""  10.0.11.0/24

# jumphost SG: SSH from the deploy-time allow-list (remove+re-add so a
# re-run with a different ALLOW_SSH_CIDR_RANGE updates the rule).
ensure_sg enterprise-datacenter-jumphost-sg enterprise-datacenter-vpc
ensure_rule enterprise-datacenter-jumphost-sg allow-egress  Egress  All "" 0.0.0.0/0
evroc networking securitygroup removerule enterprise-datacenter-jumphost-sg --name=allow-ssh >/dev/null 2>&1 || true
ensure_rule enterprise-datacenter-jumphost-sg allow-ssh     Ingress TCP 22 "$ALLOW_SSH_CIDR_RANGE"
ensure_rule enterprise-datacenter-jumphost-sg allow-intra   Ingress All "" 10.0.10.0/24
ensure_rule enterprise-datacenter-jumphost-sg allow-tunnel  Ingress All "" 10.0.11.0/24

say "== enterprise-datacenter: disks =="
ensure_disk enterprise-datacenter-gateway-disk
ensure_disk enterprise-datacenter-jumphost-disk
ensure_disk enterprise-datacenter-vm-disk

say "== enterprise-datacenter: gateway VM (tunnel initiator; ipsec config arrives via 04) =="
render templates/gateway.yaml.tpl cloud-init/enterprise-datacenter-gateway.yaml
ensure_vm enterprise-datacenter-gateway enterprise-datacenter-subnet \
  enterprise-datacenter-gateway-disk enterprise-datacenter-sg \
  enterprise-datacenter-gateway-pubip cloud-init/enterprise-datacenter-gateway.yaml
wait_vm_ready enterprise-datacenter-gateway
EDC_GW_PRIVATE_IP=$(wait_vm_privateip enterprise-datacenter-gateway); env_set EDC_GW_PRIVATE_IP "$EDC_GW_PRIVATE_IP"
echo "enterprise-datacenter-gateway private IP: $EDC_GW_PRIVATE_IP"

say "== enterprise-datacenter: jumphost VM =="
export GW_PRIVATE_IP="$EDC_GW_PRIVATE_IP"
render templates/enterprise-datacenter-host.yaml.tpl cloud-init/enterprise-datacenter-jumphost.yaml
ensure_vm enterprise-datacenter-jumphost enterprise-datacenter-subnet \
  enterprise-datacenter-jumphost-disk enterprise-datacenter-jumphost-sg \
  enterprise-datacenter-jumphost-pubip cloud-init/enterprise-datacenter-jumphost.yaml
wait_vm_ready enterprise-datacenter-jumphost
EDC_JUMPHOST_PRIVATE_IP=$(wait_vm_privateip enterprise-datacenter-jumphost); env_set EDC_JUMPHOST_PRIVATE_IP "$EDC_JUMPHOST_PRIVATE_IP"
echo "enterprise-datacenter-jumphost private IP: $EDC_JUMPHOST_PRIVATE_IP"

say "== enterprise-datacenter: workload VM (NO public IP; routes evroc subnets via gateway) =="
render templates/enterprise-datacenter-host.yaml.tpl cloud-init/enterprise-datacenter-vm.yaml
ensure_vm enterprise-datacenter-vm enterprise-datacenter-subnet \
  enterprise-datacenter-vm-disk enterprise-datacenter-sg \
  "" cloud-init/enterprise-datacenter-vm.yaml
wait_vm_ready enterprise-datacenter-vm
EDC_VM_PRIVATE_IP=$(wait_vm_privateip enterprise-datacenter-vm); env_set EDC_VM_PRIVATE_IP "$EDC_VM_PRIVATE_IP"
echo "enterprise-datacenter-vm private IP: $EDC_VM_PRIVATE_IP"

./gen-ssh-config.sh
say "enterprise-datacenter side deployed. Next: 04-setup-ipsec.sh"
