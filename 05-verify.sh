#!/usr/bin/env bash
# 05-verify.sh -- end-to-end health checks for the enterprise-vpn-reference-architecture:
#   1. entry points: public jumphosts reachable; gateways reachable via their
#      jumphost (gateways allow SSH from the subnet only)
#   2. exactly ONE IKE SA + child SA per gateway (duplicate SAs blackhole)
#   3. the stand-in kubeAPI (cloud-init systemd service on the evroc gateway,
#      private :6443) answers requests from the enterprise side across the
#      tunnel -- this script only READS; it starts nothing
#   4. enterprise-datacenter-vm (private IP only):
#        - routes the evroc subnets via the enterprise gateway, no stale
#          ICMP-redirect cache
#        - ICMP 0% loss + HTTP 200 to the evroc gateway across the tunnel
#   5. enterprise-datacenter-vm --> evroc-cloud-app-vm :8080 across the
#      tunnel: ICMP + HTTP 200, response body echoes the enterprise source
#      IP (proves NO SNAT on the tunnel path)
#   6. evroc-cloud-jumphost --> enterprise-datacenter-vm: ICMP backwards
#      through the tunnel
# Exit code 0 only if everything passes.
set -uo pipefail
source "$(dirname "$0")/lib/common.sh"
require_project

EDC_JUMPHOST_PUBLIC_IP=$(env_get EDC_JUMPHOST_PUBLIC_IP) || die "run 03 first"
EC_JUMPHOST_PUBLIC_IP=$(env_get EC_JUMPHOST_PUBLIC_IP)   || die "run 02 first"
EDC_VM_PRIVATE_IP=$(env_get EDC_VM_PRIVATE_IP)  || die "run 03 first"
EC_APP_PRIVATE_IP=$(env_get EC_APP_PRIVATE_IP)  || die "run 02 first"
EDC_GW_PRIVATE_IP=$(env_get EDC_GW_PRIVATE_IP) || die "run 03 first"
EC_GW_PRIVATE_IP=$(env_get EC_GW_PRIVATE_IP)    || die "run 02 first"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES+1)); }
ask()  { printf '\n==> %s\n' "$*"; }
FAILURES=0

# SSH wrappers: gateways accept SSH from their subnet only, so ALL gateway
# access goes through the public jumphost of the respective side.
edc_gw()  { vm_ssh_via "$EDC_JUMPHOST_PUBLIC_IP" "$EDC_GW_PRIVATE_IP" "$1"; }
ec_gw()   { vm_ssh_via "$EC_JUMPHOST_PUBLIC_IP" "$EC_GW_PRIVATE_IP" "$1"; }
app_ssh() { # command on enterprise-datacenter-vm via the edc jumphost
  vm_ssh_via "$EDC_JUMPHOST_PUBLIC_IP" "$EDC_VM_PRIVATE_IP" "$1"; }

retry() { local n=$1; shift; local i=0
          until "$@"; do i=$((i+1)); [[ $i -ge $n ]] && return 1; sleep 10; done; }

say "1. entry points reachable (first run: cloud-init needs a few minutes)"
retry 30 vm_ssh "$EDC_JUMPHOST_PUBLIC_IP" true || fail "cannot ssh enterprise-datacenter-jumphost"
retry 30 vm_ssh "$EC_JUMPHOST_PUBLIC_IP" true  || fail "cannot ssh evroc-cloud-jumphost"
retry 30 edc_gw true                            || fail "cannot reach edc gateway (via jumphost)"
retry 30 ec_gw true                             || fail "cannot reach ec gateway (via jumphost)"
[[ $FAILURES -eq 0 ]] && pass "jumphosts (public) + gateways (via jumphost) reachable"

say "2. tunnel state (expect exactly 1 ESTABLISHED + 1 INSTALLED per side)"
for pair in "enterprise:edc_gw" "evroc:ec_gw"; do
  name=${pair%%:*}; fn=${pair#*:}
  n_est=$("$fn" 'sudo ipsec statusall | grep -c ESTABLISHED' 2>/dev/null || echo 0)
  n_ins=$("$fn" 'sudo ipsec statusall | grep -c " INSTALLED"' 2>/dev/null || echo 0)
  if [[ "$n_est" == "1" && "$n_ins" == "1" ]]; then pass "$name gateway: 1 IKE SA, 1 child SA"
  else fail "$name gateway: $n_est ESTABLISHED / $n_ins INSTALLED (expect 1/1 -- duplicate SAs blackhole traffic)"; fi
done

say "3. stand-in kubeAPI on evroc-cloud-gateway :6443 (systemd service from cloud-init)"
code=$(app_ssh "curl -s --max-time 10 -o /dev/null -w '%{http_code}' http://$EC_GW_PRIVATE_IP:6443/" 2>/dev/null || true)
[[ "$code" == "200" ]] && pass "kubeAPI stand-in reachable from enterprise-datacenter-vm across the tunnel (code 200)" \
                       || fail "kubeAPI stand-in not reachable from the enterprise side (code '$code')"

say "4. enterprise-datacenter-vm ($EDC_VM_PRIVATE_IP, no public IP) <-> gateway"
route_line=$(app_ssh "ip route get $EC_GW_PRIVATE_IP" 2>/dev/null || true)
echo "    $route_line"
[[ "$route_line" == *"via $EDC_GW_PRIVATE_IP"* ]] && pass "route via enterprise gateway $EDC_GW_PRIVATE_IP" \
                                                  || fail "route to $EC_GW_PRIVATE_IP does not go via $EDC_GW_PRIVATE_IP"
if app_ssh "ip route get $EC_GW_PRIVATE_IP" 2>/dev/null | grep -q redirected; then
  app_ssh 'sudo ip route flush cache' 2>/dev/null || true
  pass "stale redirect cache flushed (gateways have send_redirects=0)"
else pass "no stale redirect cache"; fi
stats=$(app_ssh "ping -c 5 -W 2 $EC_GW_PRIVATE_IP 2>&1; true" 2>/dev/null | tail -2 | tr '\n' ' ')
echo "    ${stats:-<ping failed>}"
app_ssh "ping -c 5 -W 2 -q $EC_GW_PRIVATE_IP >/dev/null 2>&1" && pass "icmp across tunnel (0% loss)" \
                                                            || fail "icmp across tunnel"

say "5. enterprise-datacenter-vm -> evroc-cloud-app-vm ($EC_APP_PRIVATE_IP:8080)"
body=$(app_ssh "curl -s --max-time 10 http://$EC_APP_PRIVATE_IP:8080/" 2>/dev/null || true)
echo "    body: $body"
if [[ "$body" == *"your tunnel source IP is $EDC_VM_PRIVATE_IP"* ]]; then
  pass "http 200 across tunnel AND source IP preserved ($EDC_VM_PRIVATE_IP) -- no SNAT"
else
  fail "app not reachable or source IP wrong (body: '$body')"
fi

say "6. evroc-cloud-jumphost -> enterprise-datacenter-vm, backwards through the tunnel"
vm_ssh "$EC_JUMPHOST_PUBLIC_IP" "ping -c 3 -W 2 -q $EDC_VM_PRIVATE_IP >/dev/null 2>&1" \
  && pass "icmp backwards across tunnel" \
  || fail "icmp from evroc jumphost to $EDC_VM_PRIVATE_IP"

say "result"
if [[ $FAILURES -eq 0 ]]; then echo "ALL CHECKS PASSED"
else echo "$FAILURES CHECK(S) FAILED" >&2; exit 1; fi
