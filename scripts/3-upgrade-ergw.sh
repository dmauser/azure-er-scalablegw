#!/usr/bin/env bash
# =============================================================================
# Script 3 — Upgrade ExpressRoute Gateway: ErGw1AZ → ErGwScale
# =============================================================================
# Usage: bash scripts/3-upgrade-ergw.azcli
#
# IMPORTANT: Run scripts/5-monitor-downtime.sh in a separate terminal BEFORE
# starting this upgrade to capture any connectivity interruption.
#
# What happens during the upgrade:
#   - Azure performs an in-place live migration of the gateway
#   - Existing ER connections remain attached throughout
#   - BGP sessions may briefly flap (typically milliseconds to a few seconds)
#   - The upgrade duration is typically 20-45 minutes
#   - No manual reconnection of circuits is needed post-upgrade
#
# After upgrade, ErGwScale provides:
#   - Auto-scaling throughput (no fixed limit)
#   - Higher connection density
#   - Better performance under burst traffic
# =============================================================================

set -euo pipefail

# ─── Parameters ──────────────────────────────────────────────────────────────
rg=lab-er-scale
hubName=az-hub
gwName="${hubName}-ergw"

# ─── Pre-upgrade Checks ──────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  PRE-UPGRADE STATUS CHECK"
echo "============================================================"

echo ""
echo "--- Current Gateway Configuration ---"
az network vnet-gateway show \
    --name "$gwName" \
    --resource-group "$rg" \
    --query "{Name:name, SKU:sku.name, ProvisioningState:provisioningState, Location:location}" \
    --output table

echo ""
echo "--- Active ER Connections ---"
az network vpn-connection list \
    --resource-group "$rg" \
    --query "[?contains(name,'er-connection')].{Name:name, ProvisioningState:provisioningState, ConnectionStatus:connectionStatus}" \
    --output table

echo ""
echo "--- BGP Learned Routes (pre-upgrade baseline) ---"
az network vnet-gateway list-learned-routes \
    --name "$gwName" \
    --resource-group "$rg" \
    --output table 2>/dev/null || echo "  (No learned routes yet or gateway not fully connected)"

echo ""
echo "============================================================"
echo "  STARTING UPGRADE: ErGw1AZ → ErGwScale"
echo "============================================================"
echo ""
echo "  Gateway:   $gwName"
echo "  From SKU:  ErGw1AZ"
echo "  To SKU:    ErGwScale"
echo "  Start:     $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""
echo "  NOTE: Ensure scripts/5-monitor-downtime.sh is running in another terminal!"
echo ""

read -r -p "  Press ENTER to start the upgrade, or Ctrl+C to cancel: "

upgradeStart=$(date +%s)

# ─── Trigger the Upgrade ─────────────────────────────────────────────────────
echo ""
echo "=== Submitting upgrade request ==="
az network vnet-gateway update \
    --name "$gwName" \
    --resource-group "$rg" \
    --set "sku.name=ErGwScale" \
    --set "sku.tier=ErGwScale" \
    --no-wait \
    --output none

echo "  Upgrade submitted at $(date '+%H:%M:%S')"

# ─── Monitor Upgrade Progress ─────────────────────────────────────────────────
echo ""
echo "=== Monitoring upgrade progress (checking every 30 seconds) ==="

while true; do
    currentState=$(az network vnet-gateway show \
        --name "$gwName" \
        --resource-group "$rg" \
        --query "{ProvisioningState:provisioningState, SKU:sku.name}" \
        --output json 2>/dev/null)

    provState=$(echo "$currentState" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ProvisioningState', 'Unknown'))")
    currentSku=$(echo "$currentState" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('SKU', 'Unknown'))")
    elapsed=$(( ($(date +%s) - upgradeStart) / 60 ))

    echo "$(date '+%H:%M:%S') | State: $provState | SKU: $currentSku | Elapsed: ${elapsed}m"

    if [[ "$provState" == "Succeeded" && "$currentSku" == "ErGwScale" ]]; then
        break
    elif [[ "$provState" == "Failed" ]]; then
        echo ""
        echo "ERROR: Upgrade failed! Check the Activity Log in the Azure Portal."
        echo "  az monitor activity-log list -g $rg --offset 1h --query '[].{op:operationName.value, status:status.value, time:eventTimestamp}' -o table"
        exit 1
    fi

    sleep 30
done

upgradeEnd=$(date +%s)
upgradeDuration=$(( (upgradeEnd - upgradeStart) / 60 ))

# ─── Post-Upgrade Validation ─────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  UPGRADE COMPLETE"
echo "============================================================"
echo "  Finished:  $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "  Duration:  ${upgradeDuration} minutes"
echo ""

echo "--- New Gateway Configuration ---"
az network vnet-gateway show \
    --name "$gwName" \
    --resource-group "$rg" \
    --query "{Name:name, SKU:sku.name, ProvisioningState:provisioningState}" \
    --output table

echo ""
echo "--- Post-Upgrade ER Connections ---"
az network vpn-connection list \
    --resource-group "$rg" \
    --query "[?contains(name,'er-connection')].{Name:name, ProvisioningState:provisioningState, ConnectionStatus:connectionStatus}" \
    --output table

echo ""
echo "--- BGP Learned Routes (post-upgrade) ---"
sleep 30  # Allow BGP to re-converge
az network vnet-gateway list-learned-routes \
    --name "$gwName" \
    --resource-group "$rg" \
    --output table 2>/dev/null || echo "  (Waiting for BGP reconvergence — retry in a minute)"

echo ""
echo "  Run 'bash scripts/4-test-connectivity.sh' to validate end-to-end connectivity."
echo "  Stop the monitoring script (scripts/5-monitor-downtime.sh) and review the log."
echo "============================================================"
