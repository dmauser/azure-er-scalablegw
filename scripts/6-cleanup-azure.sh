#!/usr/bin/env bash
# =============================================================================
# Script 6 — Cleanup Azure Resources
# =============================================================================
# Usage: bash scripts/6-cleanup-azure.sh
#
# This script removes all Azure resources created by script 1:
#   - The entire resource group (VNets, VMs, Bastion, ER Gateway, ER Circuit,
#     ER Connection, Key Vault, etc.)
#   - Optionally purges the Key Vault (soft-delete, 7-day retention by default)
#
# WARNING: This action is irreversible. All resources in the resource group
#          will be permanently deleted.
# =============================================================================

set -euo pipefail

# ─── Prompt for Resource Group and Region (with defaults) ────────────────────
echo ""
read -r -p "Resource Group to delete [lab-er-scale]: " rg_input
rg="${rg_input:-lab-er-scale}"

read -r -p "Azure region            [westus3]: " location_input
location="${location_input:-westus3}"

echo ""
echo "  Resource Group : $rg"
echo "  Azure Region   : $location"
echo ""

# ─── Verify Azure CLI authentication ─────────────────────────────────────────
echo "=== Checking Azure CLI authentication ==="
if ! az account show --output none 2>/dev/null; then
    echo ""
    echo "ERROR: Not logged in to Azure CLI. Run:  az login"
    exit 1
fi

currentSub=$(az account show --query "[name, id]" -o tsv | tr '\t' ' / ')
echo "  Active subscription: $currentSub"
echo ""

# ─── Confirm destructive action ───────────────────────────────────────────────
echo "============================================================"
echo "  WARNING: The following will be permanently deleted:"
echo "  Resource Group: $rg  (ALL resources inside)"
echo "============================================================"
echo ""
read -r -p "Type the resource group name to confirm deletion: " confirm
if [[ "$confirm" != "$rg" ]]; then
    echo "Confirmation did not match. Aborting."
    exit 1
fi
echo ""

# ─── Start Timer ─────────────────────────────────────────────────────────────
start=$(date +%s)

# ─── Delete Resource Group ────────────────────────────────────────────────────
if az group show --name "$rg" --output none 2>/dev/null; then
    echo "=== Deleting resource group: $rg ==="
    echo "  (This runs asynchronously — Azure will continue cleanup in the background)"
    az group delete --name "$rg" --yes --no-wait
    echo "  Deletion initiated."
else
    echo "  Resource group '$rg' not found — nothing to delete."
fi
echo ""

# ─── Elapsed Time ─────────────────────────────────────────────────────────────
end=$(date +%s)
runtime=$((end - start))
echo "============================================================"
echo "  AZURE CLEANUP COMPLETE"
echo "============================================================"
echo "  Resource Group : $rg  (deletion in progress)"
echo ""
echo "  Note: Key Vault has soft-delete (7-day retention). To purge:"
echo "    az keyvault purge --name <kv-name> --location $location"
echo ""
echo "  Total time: $((runtime / 60)) min $((runtime % 60)) sec"
echo "============================================================"
