#!/usr/bin/env bash
# teardown.sh -- delete everything both deploy scripts created, in dependency
# order: VMs -> disks -> public IPs -> security groups -> subnets -> VPCs.
# Rendered artifacts (cloud-init/, resources.env, logs/, ssh-config-snippet)
# are removed too, but secrets/ is KEPT on purpose: the agreed PSK and the
# admin keypair survive a teardown so a re-deploy re-establishes the same
# identity (delete secrets/ manually if you really want a fresh start).
#
# "yes |" answers the interactive delete confirmations; 404s are tolerated
# so re-runs after partial teardown don't fail.
set -uo pipefail
source "$(dirname "$0")/lib/common.sh"
require_project

# With no fixed project, guard the destructive path with a confirmation that
# shows the target project. Set FORCE=1 to skip the prompt (CI / scripting).
if [[ "${FORCE:-0}" != "1" ]]; then
  printf 'About to delete ALL enterprise-vpn-reference-architecture resources\nin project "%s" (region %s).\n' \
    "$PROJECT" "${REGION:-<unset>}"
  read -r -p 'Type the project name to confirm: ' reply
  [[ "$reply" == "$PROJECT" ]] || { echo "aborted (no match)"; exit 1; }
fi

del() { # del "<description>" <command...>
  local desc=$1; shift
  say "delete $desc"
  if yes | "$@" >/dev/null 2>&1; then echo "  done"
  else echo "  skipped/already gone"; fi
}

say "VMs"
del "vm evroc-cloud-gateway"           evroc compute vm delete evroc-cloud-gateway --force
del "vm evroc-cloud-jumphost"          evroc compute vm delete evroc-cloud-jumphost --force
del "vm evroc-cloud-app-vm"            evroc compute vm delete evroc-cloud-app-vm --force
del "vm enterprise-datacenter-gateway" evroc compute vm delete enterprise-datacenter-gateway --force
del "vm enterprise-datacenter-jumphost" evroc compute vm delete enterprise-datacenter-jumphost --force
del "vm enterprise-datacenter-vm"      evroc compute vm delete enterprise-datacenter-vm --force
echo "      waiting 60s for NIC/public-IP detach to settle..."; sleep 60

say "boot disks"
del "disk evroc-cloud-gateway-disk"            evroc compute disk delete evroc-cloud-gateway-disk
del "disk evroc-cloud-jumphost-disk"           evroc compute disk delete evroc-cloud-jumphost-disk
del "disk evroc-cloud-app-disk"                evroc compute disk delete evroc-cloud-app-disk
del "disk enterprise-datacenter-gateway-disk"   evroc compute disk delete enterprise-datacenter-gateway-disk
del "disk enterprise-datacenter-jumphost-disk"  evroc compute disk delete enterprise-datacenter-jumphost-disk
del "disk enterprise-datacenter-vm-disk"        evroc compute disk delete enterprise-datacenter-vm-disk

say "public IPs (must be detached first; retried while they still exist)"
PUBIPS=(evroc-cloud-gateway-pubip evroc-cloud-jumphost-pubip
        enterprise-datacenter-gateway-pubip enterprise-datacenter-jumphost-pubip)
for _ in 1 2 3 4 5; do
  for ip in "${PUBIPS[@]}"; do
    yes | evroc networking publicip delete "$ip" >/dev/null 2>&1 || true
  done
  left=0
  for ip in "${PUBIPS[@]}"; do
    evroc networking publicip get "$ip" >/dev/null 2>&1 && left=$((left+1))
  done
  [[ $left -eq 0 ]] && break
  echo "      ... $left public IP(s) still present, retrying in 30s"; sleep 30
done

say "security groups"
del "sg evroc-cloud-jumphost-sg"    evroc networking securitygroup delete evroc-cloud-jumphost-sg
del "sg evroc-cloud-sg"             evroc networking securitygroup delete evroc-cloud-sg
del "sg enterprise-datacenter-jumphost-sg" evroc networking securitygroup delete enterprise-datacenter-jumphost-sg
del "sg enterprise-datacenter-sg"  evroc networking securitygroup delete enterprise-datacenter-sg

say "subnets"
del "subnet evroc-cloud-subnet-beta"  evroc networking subnet delete evroc-cloud-subnet-beta
del "subnet enterprise-datacenter-subnet" evroc networking subnet delete enterprise-datacenter-subnet

say "VPCs"
del "vpc evroc-cloud-vpc"             evroc networking vpc delete evroc-cloud-vpc
del "vpc enterprise-datacenter-vpc"   evroc networking vpc delete enterprise-datacenter-vpc

say "local rendered artifacts (secrets/ is intentionally kept)"
rm -rf cloud-init resources.env logs ssh-config-snippet
mkdir -p cloud-init logs
echo "  done"

say "remaining resources in project (should only list platform defaults):"
evroc compute vm list
evroc networking vpc list
evroc networking publicip list
