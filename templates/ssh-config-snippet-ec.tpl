# templates/ssh-config-snippet-ec.tpl -- evroc-cloud ("B" side) ssh entries.
# Rendered by gen-ssh-config.sh whenever the B side is deployed. The same
# SSH exposure model and gotchas apply as documented in
# templates/ssh-config-snippet-edc.tpl.

Host ec-jumphost
    HostName ${EC_JUMPHOST_PUBLIC_IP}
    User ubuntu
    IdentityFile ~/enterprise-vpn-reference-architecture/secrets/admin_ed25519

Host ec-gateway
    HostName ${EC_GW_PRIVATE_IP}
    User ubuntu
    IdentityFile ~/enterprise-vpn-reference-architecture/secrets/admin_ed25519
    ProxyJump ec-jumphost

Host ec-app-vm ${EC_APP_PRIVATE_IP}
    HostName ${EC_APP_PRIVATE_IP}
    User ubuntu
    IdentityFile ~/enterprise-vpn-reference-architecture/secrets/admin_ed25519
    ProxyJump ec-jumphost
