#!/usr/bin/env bash
# Egress rules for the device slots' Docker network: a slot runs a PR's build, so it may reach the
# internet and the box's own web ports (team backends sit behind Traefik) and nothing else.
# Run as root on the box. Safe to re-run. `--dry-run` prints the rules without applying them.
# Usage: devices/firewall.sh <docker network name> <host public ip> [--dry-run]
set -euo pipefail
net=${1:?usage: firewall.sh <docker network> <host public ip> [--dry-run]}
host_ip=${2:?usage: firewall.sh <docker network> <host public ip> [--dry-run]}
dry=${3:-}

agent_port=${AGENT_PORT:-8080}
subnet=$(docker network inspect "$net" --format '{{(index .IPAM.Config 0).Subnet}}')
chain=DEVICES-EGRESS
run() { if [ "$dry" = --dry-run ]; then echo "+ $*"; else "$@"; fi; }

run iptables -N "$chain" 2>/dev/null || run iptables -F "$chain"
# Replies to what the viewer and Traefik opened.
run iptables -A "$chain" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# Inside the slot network only the agent port is open (Traefik reaches the agent there). A slot cannot
# open any other port on another container; the agent port itself needs the token or a viewer cookie.
run iptables -A "$chain" -d "$subnet" -p tcp --dport "$agent_port" -j ACCEPT
# Backends: connections addressed to the box public IP on 80 and 443 (they are DNAT-ed to Traefik).
run iptables -A "$chain" -p tcp -m multiport --dports 80,443 -m conntrack --ctstate DNAT --ctorigdst "$host_ip" -j ACCEPT
# Everything private, link-local, carrier-grade NAT, and the box itself on any other port.
for cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10 "$host_ip/32"; do
  run iptables -A "$chain" -d "$cidr" -j DROP
done
# The rest of the internet, web ports only.
run iptables -A "$chain" -p tcp -m multiport --dports 80,443 -j ACCEPT
run iptables -A "$chain" -j DROP

# Hook the chain into DOCKER-USER (once) for everything leaving the slot network.
if [ "$dry" = --dry-run ] || ! iptables -C DOCKER-USER -s "$subnet" -j "$chain" 2>/dev/null; then
  run iptables -I DOCKER-USER -s "$subnet" -j "$chain"
fi

# Traffic from a slot to the box itself (the bridge gateway, host-bound ports such as SSH or the
# Coolify dashboard) goes through INPUT, not DOCKER-USER, so it needs its own rule: replies only.
input=DEVICES-INPUT
run iptables -N "$input" 2>/dev/null || run iptables -F "$input"
run iptables -A "$input" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
run iptables -A "$input" -j DROP
if [ "$dry" = --dry-run ] || ! iptables -C INPUT -s "$subnet" -j "$input" 2>/dev/null; then
  run iptables -I INPUT -s "$subnet" -j "$input"
fi
echo "Rules for $net ($subnet) in place. Persist them with your distro's iptables-persistent."
