#!/usr/bin/env bash
# gen-ssh-config.sh -- render ssh-config-snippet from resources.env and the
# per-side templates (ssh-config-snippet-edc.tpl / -ec.tpl), then splice it
# into ~/.ssh/config between paired BEGIN/END markers.
#
# Partial rendering: each side's entries are rendered only if that side has
# been deployed (its values exist in resources.env). Deploying 02 alone
# gives you the `ec-*` aliases; adding 03 appends the `edc-*` ones.
#
# Safety properties:
#   * the script NEVER deletes or rewrites anything outside its own
#     BEGIN/END marker pair -- entries you add below, above or after the
#     managed block are untouched
#   * a timestamped backup of ~/.ssh/config is taken before every write
#   * the one-time migration away from the old (truncating) marker first
#     verifies the old block's content byte-for-byte, and refuses to run
#     otherwise
#   * ~/.ssh/config is left at mode 600
#
# This script is purely local: it does not talk to evroc's cloud, so it
# never prints the project banner.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

SSHCFG="$HOME/.ssh/config"
BEGIN_MARK="# BEGIN enterprise-vpn-reference-architecture ssh config (managed by gen-ssh-config.sh)"
END_MARK="# END enterprise-vpn-reference-architecture ssh config"
LEGACY_MARK="# enterprise-vpn-reference-architecture ssh config (managed by gen-ssh-config.sh -- do not edit below this line)"

# --- render whichever side(s) have values in resources.env -------------------
edc_vars=(EDC_JUMPHOST_PUBLIC_IP EDC_GW_PRIVATE_IP EDC_VM_PRIVATE_IP)
ec_vars=(EC_JUMPHOST_PUBLIC_IP EC_GW_PRIVATE_IP EC_APP_PRIVATE_IP)

get_side() { # <var...> -> exports them; returns 1 if any is missing
  local var v ok=0
  for var in "$@"; do
    if v=$(env_get "$var" 2>/dev/null); then export "$var=$v"; else ok=1; fi
  done
  return $ok
}

: > ssh-config-snippet
if get_side "${edc_vars[@]}"; then
  envsubst "$(printf '${%s} ' "${edc_vars[@]}")" \
    < templates/ssh-config-snippet-edc.tpl >> ssh-config-snippet
  echo "rendered enterprise-datacenter (edc-*) ssh entries"
else
  echo "enterprise-datacenter side not deployed yet -- skipping edc-* ssh entries"
fi
if get_side "${ec_vars[@]}"; then
  envsubst "$(printf '${%s} ' "${ec_vars[@]}")" \
    < templates/ssh-config-snippet-ec.tpl >> ssh-config-snippet
  echo "rendered evroc-cloud (ec-*) ssh entries"
else
  echo "evroc-cloud side not deployed yet -- skipping ec-* ssh entries"
fi
if [[ ! -s ssh-config-snippet ]]; then
  say "no side deployed yet (resources.env has no usable values) -- nothing to install into ~/.ssh/config"
  exit 0
fi

# --- splice into ~/.ssh/config, without touching anything else -------------
mkdir -p "$HOME/.ssh"; touch "$SSHCFG"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

backup() { local b="$SSHCFG.bak.$(date +%Y%m%d%H%M%S).$$"; cp "$SSHCFG" "$b"; echo "backup: $b"; }

if grep -qF "$BEGIN_MARK" "$SSHCFG"; then
  say "refreshing managed block in ~/.ssh/config (between markers)"
  # drop the previous managed block, wherever it sits; keep everything else
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0==b{skip=1} !skip{print} $0==e{skip=0}' \
    "$SSHCFG" > "$tmp"
elif grep -qF "$LEGACY_MARK" "$SSHCFG"; then
  say "one-time migration from the old unpaired marker"
  # The legacy block is: the marker line, then exactly as many lines as the
  # previously installed snippet. Verify that extent byte-for-byte against
  # the freshly rendered snippet; anything else after it is USER content and
  # must survive. If the content does not match, refuse rather than guess.
  LINE=$(grep -nF "$LEGACY_MARK" "$SSHCFG" | head -1 | cut -d: -f1)
  SNIP_LINES=$(wc -l < ssh-config-snippet)
  if ! diff -q <(tail -n +"$((LINE+1))" "$SSHCFG" | head -n "$SNIP_LINES") \
               ssh-config-snippet >/dev/null; then
    rm -f "$tmp"
    die "legacy block content does not match the expected snippet -- edit ~/.ssh/config manually (remove the block after the legacy marker), then re-run"
  fi
  # head [before marker] + tail [after the legacy block] -- user entries
  # below the old block are preserved verbatim
  { awk -v n="$LINE" 'NR<n' "$SSHCFG"
    tail -n +"$((LINE+SNIP_LINES+1))" "$SSHCFG"; } > "$tmp"
else
  say "appending managed block to ~/.ssh/config"
  cp "$SSHCFG" "$tmp"
fi

printf '%s\n' "$BEGIN_MARK"      >> "$tmp"
cat ssh-config-snippet            >> "$tmp"
printf '%s\n' "$END_MARK"        >> "$tmp"

backup
mv "$tmp" "$SSHCFG"
trap - EXIT
chmod 600 "$SSHCFG"
echo "installed into ~/.ssh/config (mode 600)"
