#cloud-config
# VPN gateway cloud-init -- used for enterprise-datacenter-gateway and
# evroc-cloud-gateway. The strongSwan *tunnel config itself is NOT here*:
# it is provisioned later by 04-setup-ipsec.sh (agree secret -> push config
# -> initiate from the enterprise side). This cloud-init just prepares the
# host so that 04 only has to drop two files and restart:
#   * install strongswan-starter, enable (not start) the service
#   * IPv4 forwarding so the gateway routes between its subnet and the tunnel
#   * loose rp_filter (tunnel/forwarded traffic is asymmetric-ish)
#   * send_redirects=0: tunnel egress uses the same interface packets arrive
#     on; without this Linux sends ICMP redirects that lure clients into
#     using the VPC router (blackhole -- they also get cached for minutes)
#   * an MSS guardrail (systemd unit) for tunnel-destined SYNs from hosts
#     without a route-MTU hint
#   * admin ssh key (with custom user-data the platform does NOT inject
#     --ssh-authorized-key keys; cloud user is "ubuntu")
#
# Vars (subst): SSH_PUBKEY - admin public key

ssh_authorized_keys:
  - "${SSH_PUBKEY}"

package_update: true
packages:
  - strongswan-starter

write_files:
  - path: /etc/sysctl.d/99-vpn-gateway.conf
    permissions: '0644'
    content: |
      net.ipv4.ip_forward=1
      net.ipv4.conf.all.rp_filter=2
      net.ipv4.conf.default.rp_filter=2
      net.ipv4.conf.all.send_redirects=0
      net.ipv4.conf.default.send_redirects=0

  # sysctl(5) ORs the per-interface value with the "all" value for
  # send_redirects/rp_filter, and the NIC already exists when the sysctl.d
  # file is applied (so the "default" entry does not cover it). A
  # post-network oneshot re-applies the values to every interface, race-free:
  - path: /etc/systemd/system/enterprise-vpn-sysctls.service
    permissions: '0644'
    content: |
      [Unit]
      Description=enterprise-vpn per-interface sysctls
      Wants=network-online.target
      After=network-online.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/bin/sh -c 'sysctl -w net.ipv4.ip_forward=1 >/dev/null; sysctl -w net.ipv4.conf.all.send_redirects=0 net.ipv4.conf.default.send_redirects=0 >/dev/null; for f in /proc/sys/net/ipv4/conf/*/send_redirects; do echo 0 > "$f"; done'
      ExecStart=/bin/sh -c 'sysctl -w net.ipv4.conf.all.rp_filter=2 net.ipv4.conf.default.rp_filter=2 >/dev/null; for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 2 > "$f"; done'

      [Install]
      WantedBy=multi-user.target
  # MSS guardrail for tunnel-destined flows. Hosts managed by our templates
  # install "mtu 1300" on their far-side route, so their SYNs already carry
  # MSS <= 1260 and never need this. This rule is the net that catches SYNs
  # from hosts WITHOUT the route hint (e.g. phase-2 k8s nodes, production
  # enterprise hosts). Note: the earlier "--clamp-mss-to-pmtu" was a NO-OP
  # here -- it clamps to the gateway's route PMTU, which is the 1500 uplink,
  # not the tunnel's effective MTU (~1440 with ESP-in-UDP). A fixed
  # --set-mss 1260 (1300 - 40) works regardless; TCPMSS only lowers, never
  # raises, so it is harmless on flows that already negotiated lower.
  - path: /etc/systemd/system/enterprise-vpn-mss.service
    permissions: '0644'
    content: |
      [Unit]
      Description=enterprise-vpn MSS guardrail for tunnel-destined flows
      Wants=network-online.target
      After=network-online.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/sbin/iptables -t mangle -A FORWARD -d 10.0.11.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1260
      ExecStart=/usr/sbin/iptables -t mangle -A FORWARD -d 10.0.10.0/24 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1260

      [Install]
      WantedBy=multi-user.target

runcmd:
  - sysctl --system
  - iptables -P FORWARD ACCEPT
  - systemctl enable --now enterprise-vpn-sysctls.service
  - systemctl enable --now enterprise-vpn-mss.service
  - systemctl enable strongswan-starter
