#!/usr/bin/env bash
# =============================================================================
# Script 4 — SCENARIO 2: Gateway Migration: ErGwAZ → ErGwScale
# =============================================================================
# Usage: bash scripts/4-scenario2-migrate-ergw.sh
#
# ┌─────────────────────────────────────────────────────────────────────────┐
# │  SCENARIO 2 — CUSTOMER-CONTROLLED GATEWAY MIGRATION                     │
# │                                                                         │
# │  Migrates an existing ExpressRoute Gateway to a new ErGwScale gateway   │
# │  using Azure's Gateway Migration feature. Unlike Scenario 1 (in-place   │
# │  SKU change), this process deploys a brand-new gateway resource and     │
# │  transfers existing ER connections to it in a controlled sequence.       │
# │                                                                         │
# │  Migration phases                                                       │
# │                                                                         │
# │  1. PREPARE   — Azure provisions a new ErGwScale gateway alongside the  │
# │                 existing one. The old gateway and all connections remain │
# │                 fully operational. (~20–40 min)                         │
# │                                                                         │
# │  2. EXECUTE   — Connections are transferred to the new gateway. A brief │
# │                 BGP flap (typically milliseconds) may occur.            │
# │                 (~5–15 min)                                             │
# │                                                                         │
# │  3. COMMIT    — The old gateway is deleted. Migration is finalised.     │
# │      ─── OR ───                                                         │
# │     ABORT     — Roll back to the old gateway (only valid after Execute  │
# │                 and before Commit).                                     │
# │                                                                         │
# │  Why use this path instead of Scenario 1?                               │
# │    • Works for ANY source SKU — including legacy non-AZ types           │
# │      (Standard, HighPerf, UltraPerf)                                   │
# │    • Provides an explicit rollback window after Execute                 │
# │    • Full customer control over each phase                              │
# │    • Useful when you want to validate the new gateway before committing │
# │                                                                         │
# │  Docs:                                                                  │
# │  https://learn.microsoft.com/azure/expressroute/expressroute-howto-gateway-migration-portal │
# └─────────────────────────────────────────────────────────────────────────┘
#
# IMPORTANT: Run scripts/6-monitor-downtime.sh in a separate terminal BEFORE
# starting Phase 2 (Execute) to capture any connectivity interruption.
# =============================================================================

set -euo pipefail

# ─── Source shared validation library ────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/validate.sh
source "${SCRIPT_DIR}/lib/validate.sh"

# ─── REST API helper ─────────────────────────────────────────────────────────
# All migration operations are submitted via az rest (REST API) because the
# gateway migration sub-commands may not be available in all CLI versions.
# API version used: 2024-05-01
API_VERSION="2024-05-01"

# gw_rest_post <operation> [body_json]
#   Submits a POST to the gateway migration API and returns the raw response.
gw_rest_post() {
    local operation=$1
    local body="${2:-{}}"
    az rest --method POST \
        --uri "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${rg}/providers/Microsoft.Network/virtualNetworkGateways/${gwName}/${operation}?api-version=${API_VERSION}" \
        --body "$body" \
        --output json 2>/dev/null
}

# poll_gateway_state <expected_state> <timeout_minutes>
#   Polls the gateway provisioningState every 30 seconds until it matches
#   expected_state or the timeout is reached. Returns 1 on timeout/failure.
poll_gateway_state() {
    local expected=$1
    local timeout_min=${2:-60}
    local start elapsed state

    start=$(date +%s)
    echo ""
    echo "  Time     | State        | SKU          | Elapsed"
    echo "  ─────────┼──────────────┼──────────────┼──────────"

    while true; do
        state=$(az network vnet-gateway show \
            --name "$gwName" --resource-group "$rg" \
            --query "{s:provisioningState, k:sku.name}" -o json 2>/dev/null \
            || echo '{"s":"Unknown","k":"Unknown"}')

        provState=$(echo "$state" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d.get('s','Unknown'))")
        skuState=$(echo "$state" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d.get('k','Unknown'))")
        elapsed=$(( ($(date +%s) - start) / 60 ))

        printf "  %s | %-12s | %-12s | %dm\n" \
            "$(date '+%H:%M:%S')" "$provState" "$skuState" "$elapsed"

        if [[ "$provState" == "$expected" ]]; then
            return 0
        fi
        if [[ "$provState" == "Failed" ]]; then
            echo ""
            echo "  ERROR: Gateway operation failed (state=Failed)."
            echo "  Review Activity Log:"
            echo "    az monitor activity-log list -g $rg --offset 2h -o table"
            return 1
        fi
        if (( elapsed >= timeout_min )); then
            echo ""
            echo "  TIMEOUT: Gateway did not reach state '$expected' within ${timeout_min} minutes."
            return 1
        fi
        sleep 30
    done
}

# =============================================================================
# INTRODUCTION
# =============================================================================
echo ""
echo "============================================================"
echo "  SCENARIO 2: CUSTOMER-CONTROLLED GATEWAY MIGRATION"
echo "  ErGwAZ (any AZ SKU) → ErGwScale"
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
print_validation_header "SCENARIO 2 — GATEWAY MIGRATION"

validate_azure_cli_version 2 55
validate_azure_auth           # sets SUBSCRIPTION_ID, SUBSCRIPTION_NAME, TENANT_ID
validate_resource_group "$rg"
validate_gateway_exists  "$gwName" "$rg"
validate_gateway_state   "$gwName" "$rg"
validate_gateway_sku_for_migration "$gwName" "$rg"
validate_gateway_subnet_size "${hubName}-vnet" "$rg"
validate_er_connections  "$rg"
validate_no_active_migration "$gwName" "$rg"

print_validation_pass

# ─── Capture current SKU for display ─────────────────────────────────────────
sourceSku=$(az network vnet-gateway show \
    --name "$gwName" --resource-group "$rg" \
    --query "sku.name" -o tsv 2>/dev/null)

# =============================================================================
# PRE-MIGRATION BASELINE
# =============================================================================
echo "============================================================"
echo "  PRE-MIGRATION BASELINE SNAPSHOT"
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
echo "--- BGP Learned Routes (pre-migration baseline) ---"
az network vnet-gateway list-learned-routes \
    --name "$gwName" \
    --resource-group "$rg" \
    --output table 2>/dev/null || echo "  (No learned routes yet — circuit may not be connected)"

# =============================================================================
# MIGRATION PLAN CONFIRMATION
# =============================================================================
echo ""
echo "============================================================"
echo "  MIGRATION PLAN"
echo "============================================================"
echo ""
echo "  Gateway        : $gwName  (in: $rg)"
echo "  Current SKU    : $sourceSku"
echo "  Target SKU     : ErGwScale"
echo "  Method         : Customer-controlled 3-phase migration"
echo ""
echo "  Phase 1 PREPARE  — Deploy new ErGwScale gateway alongside existing"
echo "                     (~20–40 min, no service impact)"
echo "  Phase 2 EXECUTE  — Transfer ER connections to new gateway"
echo "                     (~5–15 min, brief BGP flap possible)"
echo "  Phase 3 COMMIT   — Remove old gateway  |  ABORT = rollback"
echo ""
echo "  ⚠  Start scripts/6-monitor-downtime.sh BEFORE Phase 2 (Execute)"
echo "     to capture BGP flap timing."
echo ""

read -r -p "  Press ENTER to start Phase 1 (Prepare), or Ctrl+C to cancel: "

# =============================================================================
# PHASE 1: PREPARE MIGRATION
# =============================================================================
echo ""
echo "============================================================"
echo "  PHASE 1: PREPARE — Provisioning new ErGwScale gateway"
echo "============================================================"

phaseStart=$(date +%s)
echo "  Started: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo ""
echo "  Submitting prepareMigration request..."
echo "  (This deploys a new ErGwScale gateway alongside the existing one)"
echo ""

prepareBody='{"migrationGatewaySku":"ErGwScale"}'

if ! gw_rest_post "prepareMigration" "$prepareBody" > /tmp/er-migrate-prepare.json 2>&1; then
    echo ""
    echo "  WARN: prepareMigration call returned a non-zero exit. Checking response..."
    cat /tmp/er-migrate-prepare.json 2>/dev/null || true
    echo ""
    echo "  If the error indicates the operation was accepted (202), proceed."
    echo "  Check the portal Activity Log if unsure."
fi

echo "  prepareMigration submitted. Waiting for 'Succeeded'..."
echo "  (Poll interval: 30 s | Timeout: 60 min)"

poll_gateway_state "Succeeded" 60

phaseEnd=$(date +%s)
phaseDuration=$(( (phaseEnd - phaseStart) / 60 ))

echo ""
echo "  Phase 1 complete in ${phaseDuration} minutes."
echo ""
echo "--- Gateway state after Prepare ---"
az network vnet-gateway show \
    --name "$gwName" --resource-group "$rg" \
    --query "{Name:name, SKU:sku.name, ProvisioningState:provisioningState}" \
    --output table

# =============================================================================
# PHASE 2: EXECUTE MIGRATION
# =============================================================================
echo ""
echo "============================================================"
echo "  PHASE 2: EXECUTE — Transferring connections to new gateway"
echo "============================================================"
echo ""
echo "  ⚠  This is the traffic-impacting phase."
echo "     BGP sessions will briefly flap as connections transfer."
echo "     Ensure scripts/6-monitor-downtime.sh is running NOW."
echo ""
echo "  After Execute completes, you have a window to:"
echo "    • Validate connectivity with scripts/5-test-connectivity.sh"
echo "    • Commit (permanently remove old gateway)  — recommended if OK"
echo "    • Abort  (rollback to old gateway)         — if issues found"
echo ""

read -r -p "  Press ENTER to start Phase 2 (Execute), or Ctrl+C to abort now: "

phaseStart=$(date +%s)
echo ""
echo "  Submitting executeMigration request..."
echo ""

if ! gw_rest_post "executeMigration" "{}" > /tmp/er-migrate-execute.json 2>&1; then
    echo ""
    echo "  WARN: executeMigration call returned a non-zero exit. Checking response..."
    cat /tmp/er-migrate-execute.json 2>/dev/null || true
    echo ""
fi

echo "  executeMigration submitted. Waiting for 'Succeeded'..."
echo "  (Poll interval: 30 s | Timeout: 30 min)"

poll_gateway_state "Succeeded" 30

phaseEnd=$(date +%s)
phaseDuration=$(( (phaseEnd - phaseStart) / 60 ))

echo ""
echo "  Phase 2 complete in ${phaseDuration} minutes."
echo ""
echo "--- Connections after Execute ---"
az network vpn-connection list \
    --resource-group "$rg" \
    --query "[?connectionType=='ExpressRoute'].{Name:name, Provisioning:provisioningState, Status:connectionStatus}" \
    --output table

echo ""
echo "--- BGP Routes after Execute ---"
sleep 15
az network vnet-gateway list-learned-routes \
    --name "$gwName" --resource-group "$rg" \
    --output table 2>/dev/null || echo "  (BGP may still be converging)"

# =============================================================================
# CONNECTIVITY VALIDATION WINDOW
# =============================================================================
echo ""
echo "============================================================"
echo "  VALIDATION WINDOW"
echo "============================================================"
echo ""
echo "  You can now validate connectivity before committing."
echo ""
echo "  Run in another terminal:"
echo "    bash scripts/5-test-connectivity.sh"
echo ""
echo "  Review the downtime monitor output (scripts/6-monitor-downtime.sh)."
echo ""
echo "  When ready, choose:"
echo "    COMMIT  — Delete old gateway and finalise migration [RECOMMENDED]"
echo "    ABORT   — Rollback: restore old gateway (safe until committed)"
echo ""

while true; do
    read -r -p "  Enter action [commit / abort]: " action_input
    action="${action_input,,}"
    if [[ "$action" == "commit" || "$action" == "abort" ]]; then
        break
    fi
    echo "  Invalid choice. Please type 'commit' or 'abort'."
done

# =============================================================================
# PHASE 3a: COMMIT MIGRATION
# =============================================================================
if [[ "$action" == "commit" ]]; then
    echo ""
    echo "============================================================"
    echo "  PHASE 3: COMMIT — Finalising migration"
    echo "============================================================"
    echo ""

    read -r -p "  Confirm COMMIT — old gateway will be permanently deleted [y/N]: " confirmCommit
    if [[ "${confirmCommit,,}" != "y" ]]; then
        echo "  Commit cancelled. The migration is still in Execute state."
        echo "  Run this script again and choose 'commit' or 'abort'."
        exit 0
    fi

    phaseStart=$(date +%s)
    echo ""
    echo "  Submitting commitMigration request..."

    if ! gw_rest_post "commitMigration" "{}" > /tmp/er-migrate-commit.json 2>&1; then
        echo "  WARN: commitMigration returned a non-zero exit. Checking response..."
        cat /tmp/er-migrate-commit.json 2>/dev/null || true
    fi

    echo "  commitMigration submitted. Waiting for 'Succeeded'..."
    poll_gateway_state "Succeeded" 30

    phaseEnd=$(date +%s)
    phaseDuration=$(( (phaseEnd - phaseStart) / 60 ))

    echo ""
    echo "============================================================"
    echo "  MIGRATION COMPLETE — ErGwScale is now your active gateway"
    echo "============================================================"
    echo "  Phase 3 duration : ${phaseDuration} minutes"
    echo ""

    echo "--- Final Gateway Configuration ---"
    az network vnet-gateway show \
        --name "$gwName" --resource-group "$rg" \
        --query "{Name:name, SKU:sku.name, ProvisioningState:provisioningState, Location:location}" \
        --output table

    echo ""
    echo "--- Final ER Connections ---"
    az network vpn-connection list \
        --resource-group "$rg" \
        --query "[?connectionType=='ExpressRoute'].{Name:name, Provisioning:provisioningState, Status:connectionStatus}" \
        --output table

    echo ""
    echo "--- BGP Learned Routes (final) ---"
    sleep 15
    az network vnet-gateway list-learned-routes \
        --name "$gwName" --resource-group "$rg" \
        --output table 2>/dev/null || echo "  (BGP converging — retry in 30 seconds)"

    finalSku=$(az network vnet-gateway show \
        --name "$gwName" --resource-group "$rg" \
        --query "sku.name" -o tsv 2>/dev/null)

    if [[ "$finalSku" == "ErGwScale" ]]; then
        echo ""
        echo "  ✔  Gateway successfully migrated to ErGwScale"
    else
        echo ""
        echo "  ⚠  Unexpected final SKU: $finalSku  —  check Azure Portal Activity Log"
    fi

fi

# =============================================================================
# PHASE 3b: ABORT MIGRATION (rollback)
# =============================================================================
if [[ "$action" == "abort" ]]; then
    echo ""
    echo "============================================================"
    echo "  PHASE 3: ABORT — Rolling back to original gateway"
    echo "============================================================"
    echo ""

    phaseStart=$(date +%s)
    echo "  Submitting abortMigration request..."

    if ! gw_rest_post "abortMigration" "{}" > /tmp/er-migrate-abort.json 2>&1; then
        echo "  WARN: abortMigration returned a non-zero exit. Checking response..."
        cat /tmp/er-migrate-abort.json 2>/dev/null || true
    fi

    echo "  abortMigration submitted. Waiting for 'Succeeded'..."
    poll_gateway_state "Succeeded" 30

    phaseEnd=$(date +%s)
    phaseDuration=$(( (phaseEnd - phaseStart) / 60 ))

    echo ""
    echo "============================================================"
    echo "  MIGRATION ABORTED — Original gateway restored"
    echo "============================================================"
    echo "  Rollback duration : ${phaseDuration} minutes"
    echo ""

    az network vnet-gateway show \
        --name "$gwName" --resource-group "$rg" \
        --query "{Name:name, SKU:sku.name, ProvisioningState:provisioningState}" \
        --output table

    echo ""
    echo "  The original gateway ($sourceSku) has been restored."
    echo "  ER connections remain on the original gateway."
fi

# =============================================================================
# NEXT STEPS
# =============================================================================
echo ""
echo "============================================================"
echo "  SCENARIO 2 COMPLETE — NEXT STEPS"
echo "============================================================"
echo ""
if [[ "$action" == "commit" ]]; then
    echo "  1. Stop the downtime monitor and review any logged packet-loss."
    echo ""
    echo "  2. Run connectivity tests:"
    echo "       bash scripts/5-test-connectivity.sh"
    echo ""
    echo "  3. Optional: Configure auto-scaling on ErGwScale:"
    echo "       az network vnet-gateway update \\"
    echo "         --name $gwName --resource-group $rg \\"
    echo "         --min-scale-unit 1 --max-scale-unit 10"
    echo ""
    echo "  4. Cleanup when done:"
    echo "       bash scripts/7-cleanup-azure.sh"
    echo "       bash scripts/8-cleanup-gcp.sh"
else
    echo "  Migration was aborted. Gateway is back on  $sourceSku."
    echo "  Diagnose any issues, then re-run this script when ready."
fi
echo "============================================================"
