#cloud-config
# App VM cloud-init -- evroc-cloud-app-vm (subnet 10.0.11.0/24, NO public IP).
# This is the example application reachable on a private IP from the enterprise
# datacenter through the IPSec tunnel.
#
# Responsibilities:
#   * same far-side static route as the jumphost (return path to 10.0.10.0/24
#     via the evroc-cloud VPN gateway; systemd oneshot, reboot-safe)
#   * the example HTTP endpoint: a python systemd service on :8080 that echoes
#     the requestor's source IP, i.e. the no-SNAT proof. Formerly the
#     standalone echo-server.sh one-liner -- now embedded here so it is
#     persistent across reboots and reprovisioning.
#   * loose reverse-path filtering, admin ssh key (cloud user "ubuntu")
#
# NO packages are installed: this VM has no public IP and thus no internet
# egress -- cloud-init only writes files (python3 is in the image).
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

  - path: /opt/enterprise-vpn/app.py
    permissions: '0644'
    content: |
      #!/usr/bin/env python3
      """Example endpoint: echoes the requestor's source IP.

      Curling this from the enterprise-datacenter VM through the tunnel and
      seeing the enterprise private address in the body proves the tunnel
      preserves source addresses end-to-end (no SNAT anywhere).
      """
      from http.server import BaseHTTPRequestHandler, HTTPServer

      class Handler(BaseHTTPRequestHandler):
          def do_GET(self):
              body = (
                  f"hello from evroc-cloud-app-vm - "
                  f"your tunnel source IP is {self.client_address[0]}"
              ).encode()
              self.send_response(200)
              self.send_header("Content-Type", "text/plain; charset=utf-8")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

      HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()

  - path: /etc/systemd/system/enterprise-vpn-app.service
    permissions: '0644'
    content: |
      [Unit]
      Description=enterprise-vpn app server (stand-in for a NodePort workload)
      After=network-online.target

      [Service]
      ExecStart=/usr/bin/python3 /opt/enterprise-vpn/app.py
      Restart=always

      [Install]
      WantedBy=multi-user.target

runcmd:
  - sysctl --system
  - systemctl enable --now enterprise-vpn-static-routes.service
  - systemctl enable --now enterprise-vpn-app.service
