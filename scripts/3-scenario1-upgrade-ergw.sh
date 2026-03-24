#!/usr/bin/env bash
# =============================================================================
# Script 3 — SCENARIO 1: In-Place Upgrade: ErGwAZ → ErGwScale
# =============================================================================
# Usage: bash scripts/3-scenario1-upgrade-ergw.sh
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │  SCENARIO 1 — IN-PLACE SKU UPGRADE                                      │
# │                                                                         │
# │  Upgrades an existing AZ-enabled ExpressRoute Gateway                   │
# │  (ErGw1AZ / ErGw2AZ / ErGw3AZ) to ErGwScale in-place, WITHOUT          │
# │  replacing or recreating the gateway resource.                          │
# │                                                                         │
# │  How it works                                                           │
# │    1. Azure receives the SKU change request                             │
# │    2. The gateway is migrated live — no service interruption expected   │
# │    3. ER connections remain attached throughout                         │
# │    4. BGP sessions may briefly flap (typically milliseconds)            │
# │    5. Duration: ~20–45 minutes                                          │
# │                                                                         │
# │  Prerequisites                                                          │
# │    • Source SKU must be ErGw1AZ, ErGw2AZ, or ErGw3AZ                   │
# │    • GatewaySubnet must be /26 or larger                               │
# │    • Gateway provisioningState must be Succeeded                        │
# │                                                                         │
# │  Compare with Scenario 2 (script 4):                                   │
# │    Scenario 1 modifies the existing gateway object.                     │
# │    Scenario 2 deploys a new gateway and migrates connections.           │
# └─────────────────────────────────────────────────────────────────────────┘
#
# IMPORTANT: Run scripts/6-monitor-downtime.sh in a separate terminal BEFORE
# starting this upgrade to capture any connectivity interruption.
# =============================================================================

set -euo pipefail

# ─── Source shared validation library ────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/validate.sh
source "${SCRIPT_DIR}/lib/validate.sh"

# ─── Parameters (prompt with defaults) ───────────────────────────────────────
echo ""
echo "============================================================"
echo "  SCENARIO 1: IN-PLACE EXPRESSROUTE GATEWAY UPGRADE"
echo "  ErGwAZ (1AZ / 2AZ / 3AZ) → ErGwScale"
echo "============================================================"
echo ""

read -r -p "Resource Group name [lab-er-scale]: " rg_input
rg="${rg_input:-lab-er-scale}"

read -r -p "Hub VNet name prefix [az-hub]: " hubName_input
hubName="${hubName_input:-az-hub}"

gwName="${hubName}-ergw"
erCircuitName=er-lab-circuit

echo ""
echo "  Resource Group : $rg"
echo "  Gateway name   : $gwName"
echo ""

# =============================================================================
# PRE-FLIGHT VALIDATION
# =============================================================================
print_validation_header "SCENARIO 1 — IN-PLACE UPGRADE"

validate_azure_cli_version 2 55
validate_azure_auth
validate_resource_group "$rg"
validate_gateway_exists  "$gwName" "$rg"
validate_gateway_state   "$gwName" "$rg"
validate_gateway_sku_for_inplace_upgrade "$gwName" "$rg"
validate_gateway_subnet_size "${hubName}-vnet" "$rg"
validate_er_connections  "$rg"
validate_no_active_migration "$gwName" "$rg"

print_validation_pass

# ─── Capture current SKU for display ─────────────────────────────────────────
currentSku=$(az network vnet-gateway show \
    --name "$gwName" --resource-group "$rg" \
    --query "sku.name" -o tsv 2>/dev/null)

# =============================================================================
# PRE-UPGRADE BASELINE
# =============================================================================
echo "============================================================"
echo "  PRE-UPGRADE BASELINE SNAPSHOT"
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
    --query "[?connectionType=='ExpressRoute'].{Name:name, Provisioning:provisioningState, Status:connectionStatus}" \
    --output table

echo ""
echo "--- BGP Learned Routes (pre-upgrade baseline) ---"
az network vnet-gateway list-learned-routes \
    --name "$gwName" \
    --resource-group "$rg" \
    --output table 2>/dev/null || echo "  (No learned routes yet — circuit may not be connected)"

# =============================================================================
# UPGRADE CONFIRMATION
# =============================================================================
echo ""
echo "============================================================"
echo "  UPGRADE PLAN"
echo "============================================================"
echo ""
echo "  Gateway        : $gwName  (in: $rg)"
echo "  Current SKU    : $currentSku"
echo "  Target SKU     : ErGwScale"
echo "  Method         : In-place SKU change (no gateway re-creation)"
echo "  Expected time  : 20–45 minutes"
echo "  Downtime risk  : Near-zero; BGP flap of milliseconds only"
echo ""
echo "  ⚠  Ensure scripts/6-monitor-downtime.sh is running in another"
echo "     terminal BEFORE pressing ENTER to capture any micro-outage."
echo ""

read -r -p "  Press ENTER to start the upgrade, or Ctrl+C to cancel: "

upgradeStart=$(date +%s)
echo ""
echo "  Upgrade started at $(date '+%Y-%m-%d %H:%M:%S %Z')"

# =============================================================================
# TRIGGER THE UPGRADE
# =============================================================================
echo ""
echo "=== Submitting upgrade request ==="
az network vnet-gateway update \
    --name "$gwName" \
    --resource-group "$rg" \
    --set "sku.name=ErGwScale" \
    --set "sku.tier=ErGwScale" \
    --no-wait \
    --output none

echo "  Upgrade request submitted at $(date '+%H:%M:%S')"

# =============================================================================
# MONITOR UPGRADE PROGRESS (poll every 30 seconds)
# =============================================================================
echo ""
echo "=== Monitoring upgrade progress ==="
echo "    (checking every 30 seconds — typical duration: 20–45 min)"
echo ""
echo "  Time     | State        | SKU          | Elapsed"
echo "  ─────────┼──────────────┼──────────────┼──────────"

while true; do
    currentState=$(az network vnet-gateway show \
        --name "$gwName" \
        --resource-group "$rg" \
        --query "{ProvisioningState:provisioningState, SKU:sku.name}" \
        --output json 2>/dev/null || echo '{"ProvisioningState":"Unknown","SKU":"Unknown"}')

    provState=$(echo "$currentState" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('ProvisioningState','Unknown'))")
    skuState=$(echo "$currentState" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d.get('SKU','Unknown'))")
    elapsed=$(( ($(date +%s) - upgradeStart) / 60 ))

    printf "  %s | %-12s | %-12s | %dm\n" \
        "$(date '+%H:%M:%S')" "$provState" "$skuState" "$elapsed"

    if [[ "$provState" == "Succeeded" && "$skuState" == "ErGwScale" ]]; then
        break
    elif [[ "$provState" == "Failed" ]]; then
        echo ""
        echo "  ERROR: Upgrade failed! Review the Activity Log:"
        echo "    az monitor activity-log list -g $rg --offset 2h \\"
        echo "      --query '[].{op:operationName.value,status:status.value,time:eventTimestamp}' -o table"
        exit 1
    fi

    sleep 30
done

upgradeEnd=$(date +%s)
upgradeDuration=$(( (upgradeEnd - upgradeStart) / 60 ))

# =============================================================================
# POST-UPGRADE VALIDATION
# =============================================================================
echo ""
echo "============================================================"
echo "  UPGRADE COMPLETE"
echo "============================================================"
echo "  Finished   : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "  Duration   : ${upgradeDuration} minutes"
echo ""

echo "--- New Gateway Configuration ---"
az network vnet-gateway show \
    --name "$gwName" \
    --resource-group "$rg" \
    --query "{Name:name, SKU:sku.name, ProvisioningState:provisioningState, Location:location}" \
    --output table

echo ""
echo "--- Post-Upgrade ER Connections ---"
az network vpn-connection list \
    --resource-group "$rg" \
    --query "[?connectionType=='ExpressRoute'].{Name:name, Provisioning:provisioningState, Status:connectionStatus}" \
    --output table

echo ""
echo "--- BGP Learned Routes (post-upgrade) ---"
echo "  Waiting 30 seconds for BGP to re-converge..."
sleep 30
az network vnet-gateway list-learned-routes \
    --name "$gwName" \
    --resource-group "$rg" \
    --output table 2>/dev/null || echo "  (Waiting for BGP reconvergence — retry in a minute)"

echo ""
echo "--- Post-Upgrade Gateway SKU Confirmation ---"
finalSku=$(az network vnet-gateway show \
    --name "$gwName" --resource-group "$rg" \
    --query "sku.name" -o tsv 2>/dev/null)

if [[ "$finalSku" == "ErGwScale" ]]; then
    echo "  ✔  Gateway SKU successfully upgraded to ErGwScale"
else
    echo "  ⚠  Unexpected final SKU: $finalSku (expected ErGwScale)"
    echo "     Check the Azure Portal Activity Log for details."
fi

# =============================================================================
# NEXT STEPS
# =============================================================================
echo ""
echo "============================================================"
echo "  SCENARIO 1 COMPLETE — NEXT STEPS"
echo "============================================================"
echo ""
echo "  1. Stop the downtime monitor (Ctrl+C in the monitoring terminal)"
echo "     and review any logged packet-loss events."
echo ""
echo "  2. Run connectivity tests to validate end-to-end routing:"
echo "       bash scripts/5-test-connectivity.sh"
echo ""
echo "  3. Optional: Configure auto-scaling on the new ErGwScale gateway:"
echo "       az network vnet-gateway update \\"
echo "         --name $gwName --resource-group $rg \\"
echo "         --min-scale-unit 1 --max-scale-unit 10"
echo ""
echo "  4. Cleanup when done:"
echo "       bash scripts/7-cleanup-azure.sh"
echo "       bash scripts/8-cleanup-gcp.sh"
echo "============================================================"
