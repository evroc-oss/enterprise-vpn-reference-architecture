#cloud-config
# Host cloud-init -- used for enterprise-datacenter-vm and
# enterprise-datacenter-jumphost ("A" side / enterprise datacenter, subnet
# 10.0.10.0/24).
#
# Responsibilities:
#   * static routes for the far side (evroc cloud) subnets via the
#     enterprise-datacenter VPN gateway. Installed by a systemd oneshot
#     after network-online.target -- NOT cloud-init bootcmd: bootcmd runs
#     pre-network, races networkd, and silently loses the routes on reboots
#     (found out the hard way when the platform rebooted all VMs).
#   * loose reverse-path filtering for tunnel-decapsulated traffic
#   * admin ssh key (cloud user "ubuntu")
#
# NO packages are installed: enterprise-datacenter-vm has no public IP and
# thus no internet egress -- cloud-init only writes files.
#
# Vars (subst): GW_PRIVATE_IP - enterprise-datacenter-gateway's private IP
#                              (route next-hop)
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
      ExecStart=/usr/sbin/ip route replace 10.0.11.0/24 via ${GW_PRIVATE_IP} mtu 1300

      [Install]
      WantedBy=multi-user.target

runcmd:
  - sysctl --system
  - systemctl enable --now enterprise-vpn-static-routes.service
