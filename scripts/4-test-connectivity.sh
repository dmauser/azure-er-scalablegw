#!/usr/bin/env bash
# =============================================================================
# Script 4 — Test Connectivity and Validate ExpressRoute Paths
# =============================================================================
# Usage: bash scripts/4-test-connectivity.sh
#
# This script validates:
#   1. ExpressRoute Gateway BGP peers and learned routes
#   2. Effective routes on all VM NICs (hub, spoke1, spoke2)
#   3. ICMP (ping) from spoke VMs to the on-premises GCP VM
#   4. Traceroute from spoke VMs to verify ER path
#   5. Spoke-to-spoke connectivity via hub gateway
#
# Set ONPREM_IP to the GCP VM's internal IP before running.
# =============================================================================

set -euo pipefail

# ─── Parameters ──────────────────────────────────────────────────────────────
rg=lab-er-scale
hubName=az-hub
spoke1Name=az-spk1
spoke2Name=az-spk2
gwName="${hubName}-ergw"
erCircuitName=er-lab-circuit

# ─── CONFIGURE THIS ──────────────────────────────────────────────────────────
ONPREM_IP="192.168.0.x"   # Replace with actual GCP VM internal IP
# ─────────────────────────────────────────────────────────────────────────────

# Helper to run commands in a VM via Azure Run Command
run_in_vm() {
    local vmName=$1
    local script=$2
    az vm run-command invoke \
        --resource-group "$rg" \
        --name "$vmName" \
        --command-id RunShellScript \
        --scripts "$script" \
        --query 'value[0].message' \
        --output tsv 2>/dev/null
}

# ─── Section Header ───────────────────────────────────────────────────────────
section() { echo ""; echo "============================================================"; echo "  $1"; echo "============================================================"; }

# =============================================================================
section "1. EXPRESSROUTE CIRCUIT STATUS"
# =============================================================================
az network express-route show \
    --name "$erCircuitName" \
    --resource-group "$rg" \
    --query "{Name:name, ProviderState:serviceProviderProvisioningState, CircuitProvisioningState:circuitProvisioningState, Bandwidth:serviceProviderProperties.bandwidthInMbps}" \
    --output table

# =============================================================================
section "2. EXPRESSROUTE GATEWAY — BGP PEER STATUS"
# =============================================================================
echo "  Checking BGP peer sessions on $gwName ..."
az network vnet-gateway list-bgp-peer-status \
    --name "$gwName" \
    --resource-group "$rg" \
    --output table 2>/dev/null || echo "  [WARN] Unable to retrieve BGP peer status — gateway may still be converging."

# =============================================================================
section "3. EXPRESSROUTE GATEWAY — LEARNED ROUTES"
# =============================================================================
echo "  Routes learned from on-premises via BGP:"
az network vnet-gateway list-learned-routes \
    --name "$gwName" \
    --resource-group "$rg" \
    --output table 2>/dev/null || echo "  [WARN] No learned routes yet."

# =============================================================================
section "4. EFFECTIVE ROUTES — HUB VM NIC"
# =============================================================================
az network nic show-effective-route-table \
    --name "${hubName}-vm-nic" \
    --resource-group "$rg" \
    --output table 2>/dev/null || echo "  [WARN] Could not retrieve effective routes for hub VM NIC."

# =============================================================================
section "5. EFFECTIVE ROUTES — SPOKE1 VM NIC"
# =============================================================================
az network nic show-effective-route-table \
    --name "${spoke1Name}-vm-nic" \
    --resource-group "$rg" \
    --output table 2>/dev/null || echo "  [WARN] Could not retrieve effective routes for spoke1 VM NIC."

# =============================================================================
section "6. EFFECTIVE ROUTES — SPOKE2 VM NIC"
# =============================================================================
az network nic show-effective-route-table \
    --name "${spoke2Name}-vm-nic" \
    --resource-group "$rg" \
    --output table 2>/dev/null || echo "  [WARN] Could not retrieve effective routes for spoke2 VM NIC."

# =============================================================================
section "7. ICMP TEST — SPOKE1 → ON-PREMISES ($ONPREM_IP)"
# =============================================================================
if [[ "$ONPREM_IP" == "192.168.0.x" ]]; then
    echo "  [SKIP] ONPREM_IP not configured. Edit this script and set ONPREM_IP."
else
    echo "  Running ping test from ${spoke1Name}-vm to $ONPREM_IP ..."
    result=$(run_in_vm "${spoke1Name}-vm" "ping -c 10 -W 2 $ONPREM_IP 2>&1")
    echo "$result"
fi

# =============================================================================
section "8. TRACEROUTE — SPOKE1 → ON-PREMISES ($ONPREM_IP)"
# =============================================================================
if [[ "$ONPREM_IP" == "192.168.0.x" ]]; then
    echo "  [SKIP] ONPREM_IP not configured."
else
    echo "  Running traceroute from ${spoke1Name}-vm to $ONPREM_IP ..."
    result=$(run_in_vm "${spoke1Name}-vm" "traceroute -n -m 20 -w 2 $ONPREM_IP 2>&1 || tracepath -n $ONPREM_IP 2>&1")
    echo "$result"
fi

# =============================================================================
section "9. SPOKE-TO-SPOKE CONNECTIVITY TEST (Spoke1 → Spoke2)"
# =============================================================================
spoke2Ip=$(az network nic show \
    --name "${spoke2Name}-vm-nic" \
    --resource-group "$rg" \
    --query "ipConfigurations[0].privateIPAddress" \
    --output tsv 2>/dev/null || echo "")

if [[ -n "$spoke2Ip" ]]; then
    echo "  Spoke2 VM IP: $spoke2Ip"
    echo "  Running ping test from ${spoke1Name}-vm to ${spoke2Name}-vm ($spoke2Ip) ..."
    result=$(run_in_vm "${spoke1Name}-vm" "ping -c 5 -W 2 $spoke2Ip 2>&1")
    echo "$result"
else
    echo "  [WARN] Could not retrieve Spoke2 VM IP."
fi

# =============================================================================
section "10. GATEWAY CURRENT SKU"
# =============================================================================
az network vnet-gateway show \
    --name "$gwName" \
    --resource-group "$rg" \
    --query "{Name:name, SKU:sku.name, ProvisioningState:provisioningState}" \
    --output table

echo ""
echo "============================================================"
echo "  CONNECTIVITY TEST COMPLETE — $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
