# templates/ssh-config-snippet-edc.tpl -- enterprise-datacenter ("A" side)
# ssh entries. Rendered by gen-ssh-config.sh whenever the A side is deployed.
#
# SSH exposure model: the jump host is the only public entry point (gated by
# ALLOW_SSH_CIDR_RANGE at deploy time); gateways and private VMs accept SSH
# from their own subnet only, i.e. via the jump host. An explicit
# IdentityFile per Host is required: command-line "ssh -i key -J ..." does
# NOT pass -i to the jump connection. Jump hosts hold only the PUBLIC key;
# hopping onward from their shell needs agent forwarding (ssh -A), never
# copy private keys around.

Host edc-jumphost
    HostName ${EDC_JUMPHOST_PUBLIC_IP}
    User ubuntu
    IdentityFile ~/enterprise-vpn-reference-architecture/secrets/admin_ed25519

Host edc-gateway
    HostName ${EDC_GW_PRIVATE_IP}
    User ubuntu
    IdentityFile ~/enterprise-vpn-reference-architecture/secrets/admin_ed25519
    ProxyJump edc-jumphost

Host edc-vm ${EDC_VM_PRIVATE_IP}
    HostName ${EDC_VM_PRIVATE_IP}
    User ubuntu
    IdentityFile ~/enterprise-vpn-reference-architecture/secrets/admin_ed25519
    ProxyJump edc-jumphost
