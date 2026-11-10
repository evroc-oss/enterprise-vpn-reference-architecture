#!/usr/bin/env bash
# lib/common.sh -- shared helpers for the enterprise-vpn-reference-architecture
# scripts. Sourced by 01..05, gen-ssh-config.sh and teardown.sh. Not runnable
# on its own.
#
# Scripts that TOUCH the cloud must call `require_project` first (prints the
# target banner once and fails if no project is selected). Purely local
# scripts (01, gen-ssh-config.sh) never call it and so never talk to evroc.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

say()  { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

_require_project_done=0
require_project() { # guard + banner for every script that talks to evroc's cloud
  (( _require_project_done )) && return 0
  _require_project_done=1
  # All resources are created in whatever project is currently selected with
  # the evroc CLI. Create a project in evroc's cloud and select it first:
  #   evroc login                                  # org + project + region
  #   evroc config current-project                  # to confirm
  local region project
  region="$(evroc config current-region 2>/dev/null)"
  project="$(evroc config current-project 2>/dev/null)"
  if [[ -z "$project" ]]; then
    printf 'ERROR: no evroc project selected.\n' >&2
    printf '  Create a project in evroc'"'"'s cloud and select it:\n' >&2
    printf '    evroc login          # interactive; or\n' >&2
    printf '    evroc config set-project <your-project>\n' >&2
    exit 1
  fi
  REGION="$region"; PROJECT="$project"   # exported for scripts (e.g. teardown prompt)
  say "target: project $project, region ${region:-<unset>}"
}

# --- idempotent resource helpers --------------------------------------
evroc_exists()    { evroc "$@" >/dev/null 2>&1; }
sg_rule_exists()  { evroc networking securitygroup get "$1" 2>/dev/null \
                      | grep -qE "name:[[:space:]]+$2"; }

ensure_vpc()      { local id=$1 cidr=$2
                    evroc_exists networking vpc get "$id" && return 0
                    say "create vpc $id ($cidr)"
                    evroc networking vpc create "$id" --ipv4-cidr-block="$cidr" --stack-type=dual-stack; }
ensure_subnet()   { local id=$1 vpc=$2 cidr=$3 zone=$4
                    evroc_exists networking subnet get "$id" && return 0
                    say "create subnet $id ($cidr, zone $zone) in $vpc"
                    evroc networking subnet create "$id" --vpc="$vpc" \
                      --stack-type=dual-stack --ipv4-cidr-block="$cidr" --zone="$zone"; }
ensure_pubip()    { evroc_exists networking publicip get "$1" && return 0
                    say "create public ip $1"
                    evroc networking publicip create "$1"; }
ensure_sg()       { evroc_exists networking securitygroup get "$1" && return 0
                    say "create security group $1 in $2"
                    evroc networking securitygroup create "$1" --vpc="$2"; }
ensure_disk()     { evroc_exists compute disk get "$1" && return 0
                    say "create disk $1"
                    evroc compute disk create "$1" --image=ubuntu.24-04.1 --size-amount=20 --size-unit=GB --zone=a; }
ensure_rule()     { # <sg> <name> <direction> <proto> <port> <remote-cidr>
                    local sg=$1 name=$2 dir=$3 proto=$4 port=$5 remote=$6
                    sg_rule_exists "$sg" "$name" && return 0
                    local args=(addrule "$sg" --name="$name" --direction="$dir" --protocol="$proto")
                    [[ -n "$port" ]] && args+=(--port="$port")
                    say "sg $sg: add rule $name ($dir $proto${port:+/$port} $remote)"
                    local out
                    if ! out=$(evroc networking securitygroup "${args[@]}" --remote-ip-or-cidr="$remote" 2>&1); then
                      # the get-based existence check above can miss on a flaky
                      # API call; the server is the source of truth
                      if [[ "$out" == *"already has rule"* ]]; then
                        echo "  rule $name already existed (existence check was flaky) -- ok"
                        return 0
                      fi
                      printf '%s\n' "$out" >&2
                      return 1
                    fi; }
ensure_vm()       { # <id> <subnet> <disk> <sg> <pubip-or-empty> <cloud-init-file>
                    local id=$1 subnet=$2 disk=$3 sg=$4 pubip=$5 ud=$6
                    evroc_exists compute vm get "$id" && return 0
                    say "create vm $id"
                    local args=(compute vm create "$id" --running=true --compute-profile-ref=a1a.s --zone=a
                                --subnet="$subnet" --disk="$disk" --boot-from=true
                                --security-group="$sg")
                    [[ -n "$pubip" ]] && args+=(--public-ip="$pubip")
                    evroc "${args[@]}" --cloud-init-user-data="$(cat "$ud")"; }

# --- wait helpers ------------------------------------------------------
wait_status()     { # <resource-cmd...> <jq-expr> -- poll until non-empty
                    local expr=${*: -1}; local cmd=("${@:1:$#-1}")
                    local v
                    for _ in $(seq 1 60); do
                      v=$("${cmd[@]}" 2>/dev/null | jq -r "$expr // empty") || true
                      [[ -n "$v" ]] && { echo "$v"; return 0; }
                      sleep 5
                    done
                    return 1; }
wait_pubip()      { wait_status evroc networking publicip get "$1" -o json .status.publicIPv4Address \
                      || die "public IP $1 never allocated"; }
wait_vm_privateip() { wait_status evroc compute vm get "$1" -o json .status.networking.privateIPv4Address \
                      || die "private IP of $1 never assigned"; }
vm_ready()        { evroc compute vm get "$1" -o json 2>/dev/null \
                      | jq -e 'any(..; .type? == "Ready" and .status? == "True")' >/dev/null; }
wait_vm_ready()   { say "wait for VM $1 to be Ready"
                    for _ in $(seq 1 90); do vm_ready "$1" && return 0; sleep 5; done
                    die "VM $1 not Ready in time"; }

# --- resources.env bookkeeping (append/update one export line) ---------
env_set()         { # env_set KEY "value"
                    local line="export $1=\"$2\""
                    touch resources.env
                    grep -q "^export $1=" resources.env \
                      && sed -i "s|^export $1=.*|$line|" resources.env \
                      || printf '%s\n' "$line" >> resources.env; }
env_get()         { local v
                    v=$(grep -m1 "^export $1=" resources.env 2>/dev/null | sed "s|^export $1=\"||; s|\"$||")
                    [[ -n "$v" ]] && { echo "$v"; return 0; } || return 1; }

# --- run helpers -------------------------------------------------------
render()          { # render <template> <out>  (export the substitution vars first)
                    mkdir -p "$(dirname "$2")"
                    envsubst '${SSH_PUBKEY} ${LEFT_PUBLIC_IP} ${PEER_PUBLIC_IP} ${LEFT_SUBNET} ${RIGHT_SUBNET} ${AUTO} ${GW_PRIVATE_IP}' \
                      < "$1" > "$2"
                    echo "rendered $2"
                    # unfilled ${VAR} leftovers, or an empty ssh_authorized_keys entry
                    grep -qE '\$\{|^  - ""$' "$2" \
                      && die "rendered $2 contains an unfilled/empty variable" || true; }

# SSH to a VM (public IP) as the cloud user, with the repo admin key
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=15)
vm_ssh()          { local ip=$1; shift
                    [[ -f secrets/admin_ed25519 ]] || die "secrets/admin_ed25519 missing (run 01-generate-secrets.sh)"
                    ssh "${SSH_OPTS[@]}" -i "$(pwd)/secrets/admin_ed25519" "ubuntu@$ip" "$@"; }

# SSH to a private-IP VM through the public jumphost of its subnet. This is
# the ONLY way in for gateways etc.: their SGs allow SSH from the subnet
# only (the public entry point is the jumphost).
vm_ssh_via()      { local jumphost=$1 target=$2; shift 2
                    [[ -f secrets/admin_ed25519 ]] || die "secrets/admin_ed25519 missing (run 01-generate-secrets.sh)"
                    ssh "${SSH_OPTS[@]}" -i "$(pwd)/secrets/admin_ed25519" \
                      -o ProxyCommand="ssh ${SSH_OPTS[*]} -i $(pwd)/secrets/admin_ed25519 -W %h:%p ubuntu@$jumphost" \
                      "ubuntu@$target" "$@"; }

PIPED_SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15)
vm_ssh_piped()    { local ip=$1 file=$2
                    ssh "${PIPED_SSH_OPTS[@]}" -i "$(pwd)/secrets/admin_ed25519" "ubuntu@$ip" 'bash -s' < "$file"; }
