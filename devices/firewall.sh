#!/usr/bin/env bash
# Egress rules for the device slots' Docker network: a slot runs a PR's build, so it may reach the
# internet and the box's own web ports (team backends sit behind Traefik) and nothing else.
# Run as root on the box. Safe to re-run. `--dry-run` prints the rules without applying them; `--check`
# applies nothing and exits non-zero (naming what is missing) when the rules are not in place, which is
# what a reboot does to them: they live in memory. devices-firewall.service re-applies them at boot.
# Usage: devices/firewall.sh <docker network name> <host public ip> [--dry-run | --check]
set -euo pipefail
net=${1:?usage: firewall.sh <docker network> <host public ip> [--dry-run | --check]}
host_ip=${2:?usage: firewall.sh <docker network> <host public ip> [--dry-run | --check]}
dry=${3:-}

slot_ports=${SLOT_PORTS:-4180,8080}  # login proxy, agent
subnet=$(docker network inspect "$net" --format '{{(index .IPAM.Config 0).Subnet}}')
chain=DEVICES-EGRESS
input=DEVICES-INPUT
run() { if [ "$dry" = --dry-run ]; then echo "+ $*"; else "$@"; fi; }

if [ "$dry" = --check ]; then
  missing=0
  iptables -S "$chain" > /dev/null 2>&1 || { echo "MISSING: chain $chain"; missing=1; }
  iptables -S "$input" > /dev/null 2>&1 || { echo "MISSING: chain $input"; missing=1; }
  iptables -C DOCKER-USER -s "$subnet" -j "$chain" 2> /dev/null || { echo "MISSING: hook in DOCKER-USER for $subnet"; missing=1; }
  iptables -C INPUT -s "$subnet" -j "$input" 2> /dev/null || { echo "MISSING: hook in INPUT for $subnet"; missing=1; }
  [ "$missing" = 0 ] && echo "OK: the rules for $net ($subnet) are in place."
  exit "$missing"
fi

run iptables -N "$chain" 2>/dev/null || run iptables -F "$chain"
# Replies to what the viewer and Traefik opened.
run iptables -A "$chain" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# Inside the slot network only the login proxy and agent ports are open: Traefik reaches the proxy, the
# proxy reaches the agent. A slot cannot open any other port on another container; the proxy needs a
# GitHub login and the agent needs the token or a viewer cookie.
run iptables -A "$chain" -d "$subnet" -p tcp -m multiport --dports "$slot_ports" -j ACCEPT
# Backends: connections addressed to the box public IP on 80 and 443 (they are DNAT-ed to Traefik).
run iptables -A "$chain" -p tcp -m multiport --dports 80,443 -m conntrack --ctstate DNAT --ctorigdst "$host_ip" -j ACCEPT
# Everything private, link-local, carrier-grade NAT, and the box itself on any other port.
for cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10 "$host_ip/32"; do
  run iptables -A "$chain" -d "$cidr" -j DROP
done
# Name lookups, after the drops above so they only reach public resolvers: Docker's resolver forwards
# from the slot's own network namespace to the box's upstream resolvers. Without this the app cannot
# resolve the backend. Port 53 on a private address or on the box itself stays blocked.
run iptables -A "$chain" -p udp --dport 53 -j ACCEPT
run iptables -A "$chain" -p tcp --dport 53 -j ACCEPT
# The rest of the internet, web ports only.
run iptables -A "$chain" -p tcp -m multiport --dports 80,443 -j ACCEPT
run iptables -A "$chain" -j DROP

# Hook the chain into DOCKER-USER (once) for everything leaving the slot network.
if [ "$dry" = --dry-run ] || ! iptables -C DOCKER-USER -s "$subnet" -j "$chain" 2>/dev/null; then
  run iptables -I DOCKER-USER -s "$subnet" -j "$chain"
fi

# Traffic from a slot to the box itself (the bridge gateway, host-bound ports such as SSH or the
# Coolify dashboard) goes through INPUT, not DOCKER-USER, so it needs its own rule: replies only.
run iptables -N "$input" 2>/dev/null || run iptables -F "$input"
run iptables -A "$input" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
run iptables -A "$input" -j DROP
if [ "$dry" = --dry-run ] || ! iptables -C INPUT -s "$subnet" -j "$input" 2>/dev/null; then
  run iptables -I INPUT -s "$subnet" -j "$input"
fi
echo "Rules for $net ($subnet) in place. They are held in memory: install devices-firewall.service so a reboot re-applies them (devices/README.md)."
