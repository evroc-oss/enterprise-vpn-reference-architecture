# templates/ipsec.conf.tpl -- strongSwan site-to-site config for the
# enterprise-datacenter <-> evroc-cloud tunnel. Rendered TWICE by
# 04-setup-ipsec.sh (once per gateway) and pushed over SSH:
#   * enterprise-datacenter-gateway: AUTO=start  (single initiator; the
#     tunnel is always initialised from the enterprise/"A" side)
#   * evroc-cloud-gateway:            AUTO=add    (responder only)
#
# Exactly ONE side must initiate: concurrent initiation creates two IKE SAs
# whose unrelated child SAs overlap on the same selectors -- traffic lands
# on SPIs the peer does not expect -> intermittent/total blackhole.
#
# forceencaps=yes: ESP rides inside UDP (NAT-T). Security groups can only
# express TCP/UDP/ICMP/All, not IP protocol 50 (ESP), so the tunnel must be
# UDP-encapsulated. Identities are the PUBLIC IPs of both gateways because
# the platform 1:1 NATs the public IP onto the VM's private address.
#
# Vars (subst): LEFT_PUBLIC_IP  - this gateway's public IP (IKE identity)
#               PEER_PUBLIC_IP - the other gateway's public IP
#               LEFT_SUBNET    - this side's tunnel selector
#               RIGHT_SUBNET   - far side's tunnel selector
#               AUTO           - start | add

config setup
  uniqueids=yes

conn %default
  keyexchange=ikev2
  authby=psk
  ikelifetime=1h
  lifetime=20m
  forceencaps=yes
  mobike=no
  keyingtries=%forever
  dpdaction=restart
  ike=aes256gcm16-prfsha384-ecp384!
  esp=aes256gcm16-ecp384!

conn enterprise-vpn
  # left is this node behind the platform's 1:1 NAT; identity is the public IP
  left=%defaultroute
  leftid=${LEFT_PUBLIC_IP}
  leftsubnet=${LEFT_SUBNET}
  right=${PEER_PUBLIC_IP}
  rightid=${PEER_PUBLIC_IP}
  rightsubnet=${RIGHT_SUBNET}
  auto=${AUTO}
