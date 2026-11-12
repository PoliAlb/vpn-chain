#!/bin/sh
# Eseguito da OpenVPN (hop 2) subito dopo la creazione di tun1.
set -e
DEV="${dev:-tun1}"

# 1) il server di vpn2 deve restare raggiungibile via tun0 (= dentro vpn1)
ip route replace "${trusted_ip}/32" dev tun0

# 2) tutto il resto esce da tun1. Quattro /2 sono piu' specifiche dei /1 di
#    vpn1, quindi vincono. "dev" ESPLICITO: vpn1 e vpn2 hanno entrambi gateway
#    10.41.0.1 sulla stessa sottorete, e con "via 10.41.0.1" il kernel
#    sceglierebbe tun0 invece di tun1.
for net in 0.0.0.0/2 64.0.0.0/2 128.0.0.0/2 192.0.0.0/2; do
    ip route replace "$net" dev "$DEV"
done
