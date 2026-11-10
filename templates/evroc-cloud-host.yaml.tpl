#cloud-config
# Host cloud-init -- used for evroc-cloud-jumphost ("B" side / evroc cloud,
# subnet 10.0.11.0/24). Deliberately carries NO server: jump hosts are for
# admin access only (the example app lives in evroc-cloud-app-vm).
#
# Responsibilities:
#   * static route back to the enterprise-datacenter subnet (10.0.10.0/24)
#     via the evroc-cloud VPN gateway, so tunnel traffic has a return path
#     to hosts that sit behind the enterprise side. systemd oneshot after
#     network-online.target (reboot-safe, see enterprise-datacenter-host).
#   * loose reverse-path filtering for tunnel-decapsulated traffic
#   * admin ssh key (cloud user "ubuntu")
#
# Vars (subst): GW_PRIVATE_IP - evroc-cloud-gateway's private IP (next-hop)
#               SSH_PUBKEY   - admin public key

ssh_authorized_keys:
  - "${SSH_PUBKEY}"

write_files:
  - path: /etc/sysctl.d/99-static-routes.conf
    permissions: '0644'
    content: |
      net.ipv4.conf.all.rp_filter=2
      net.ipv4.conf.default.rp_filter=2

  - path: /etc/systemd/system/enterprise-vpn-static-routes.service
    permissions: '0644'
    content: |
      [Unit]
      Description=enterprise-vpn static routes via VPN gateway
      Wants=network-online.target
      After=network-online.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/usr/sbin/ip route replace 10.0.10.0/24 via ${GW_PRIVATE_IP} mtu 1300

      [Install]
      WantedBy=multi-user.target

runcmd:
  - sysctl --system
  - systemctl enable --now enterprise-vpn-static-routes.service
