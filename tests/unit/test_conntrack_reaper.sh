#!/bin/bash
# The conntrack reaper (ADR-022) picks only redirected connections whose endpoint no NAT rule sends to any more.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
# shellcheck source=../../platform/kubernetes/conntrack-reaper.sh
. "$ROOT/platform/kubernetes/conntrack-reaper.sh"

ct='tcp      6 272 ESTABLISHED src=10.244.176.39 dst=172.30.123.198 sport=48558 dport=5432 src=10.244.155.17 dst=10.244.176.39 sport=5432 dport=48558 [ASSURED] mark=0 use=1
tcp      6 272 ESTABLISHED src=10.244.176.40 dst=172.30.123.198 sport=48600 dport=5432 src=10.244.176.16 dst=10.244.176.40 sport=5432 dport=48600 [ASSURED] mark=0 use=1
tcp      6 100 ESTABLISHED src=10.244.176.40 dst=203.0.113.9 sport=40000 dport=443 src=203.0.113.9 dst=192.0.2.11 sport=443 dport=40000 [ASSURED] mark=0 use=1
tcp      6 100 ESTABLISHED src=192.0.2.50 dst=192.0.2.11 sport=50000 dport=22 src=192.0.2.11 dst=192.0.2.50 sport=22 dport=50000 [ASSURED] mark=0 use=1
tcp      6 50 ESTABLISHED src=10.244.176.41 dst=172.30.0.1 sport=50100 dport=443 src=192.0.2.13 dst=10.244.176.41 sport=6443 dport=50100 [ASSURED] mark=0 use=1'
live=$'10.244.176.16:5432\n192.0.2.11:6443\n192.0.2.12:6443'
eq "$(stale_entries "$live" <<< "$ct")" $'10.244.176.39 172.30.123.198 48558 5432 10.244.155.17:5432\n10.244.176.41 172.30.0.1 50100 443 192.0.2.13:6443' \
  "stale: the old database primary and the API server of the node that went down; not the live endpoint, SNAT or plain:"
eq "$(stale_entries "" <<< "")" "" "nothing in, nothing out:"
finish
