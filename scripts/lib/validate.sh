#!/usr/bin/env bash
# =============================================================================
# scripts/lib/validate.sh  —  Shared Pre-Flight Validation Functions
# =============================================================================
# Source this file at the top of other scripts:
#
#   source "$(dirname "$0")/lib/validate.sh"
#
# All functions print a status line and return a non-zero exit code on failure.
# The calling script should use 'set -euo pipefail' so failures abort the run.
# =============================================================================

# ─── Colour Helpers ──────────────────────────────────────────────────────────
# Safe colour codes — fall back gracefully if terminal doesn't support colours
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

ok()   { echo -e "  ${GREEN}✔${RESET}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $*"; }
fail() { echo -e "  ${RED}✖${RESET}  $*" >&2; return 1; }

# ─── semver_gte <actual> <minimum> ───────────────────────────────────────────
# Returns 0 (true) if actual version >= minimum version.
# Compares only major.minor (ignores patch).
semver_gte() {
    local actual=$1 minimum=$2
    local amaj amin bmaj bmin
    amaj=$(echo "$actual"  | cut -d. -f1)
    amin=$(echo "$actual"  | cut -d. -f2)
    bmaj=$(echo "$minimum" | cut -d. -f1)
    bmin=$(echo "$minimum" | cut -d. -f2)
    if (( amaj > bmaj )); then return 0; fi
    if (( amaj == bmaj && amin >= bmin )); then return 0; fi
    return 1
}

# =============================================================================
# validate_tools
#   Checks that required CLI tools are installed.
# =============================================================================
validate_tools() {
    echo ""
    echo "${BOLD}─── Tool availability check ───────────────────────────────${RESET}"
    local failed=0

    for tool in az python3 jq; do
        if command -v "$tool" &>/dev/null; then
            ok "$tool  found at $(command -v "$tool")"
        else
            if [[ "$tool" == "jq" ]]; then
                warn "jq not found — JSON parsing will fall back to python3  (install: apt-get install jq)"
            else
                fail "$tool not installed or not in PATH"; failed=1
            fi
        fi
    done

    (( failed == 0 )) || { echo ""; echo "Resolve the missing tools above before continuing."; return 1; }
}

# =============================================================================
# validate_azure_cli_version [min_major] [min_minor]
#   Default minimum: 2.55
# =============================================================================
validate_azure_cli_version() {
    local min_major=${1:-2} min_minor=${2:-55}
    echo ""
    echo "${BOLD}─── Azure CLI version check ────────────────────────────────${RESET}"

    if ! command -v az &>/dev/null; then
        fail "Azure CLI not found. Install: https://aka.ms/installazureclilinux"
        return 1
    fi

    local version
    version=$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo "0.0")
    local actual_major actual_minor
    actual_major=$(echo "$version" | cut -d. -f1)
    actual_minor=$(echo "$version" | cut -d. -f2)

    if semver_gte "$version" "${min_major}.${min_minor}"; then
        ok "Azure CLI ${version} (minimum ${min_major}.${min_minor})"
    else
        fail "Azure CLI ${version} is below minimum ${min_major}.${min_minor}"
        echo "     Upgrade: az upgrade"
        return 1
    fi
}

# =============================================================================
# validate_bicep_version [min_major] [min_minor]
#   Default minimum: 0.22
# =============================================================================
validate_bicep_version() {
    local min_major=${1:-0} min_minor=${2:-22}
    echo ""
    echo "${BOLD}─── Bicep version check ────────────────────────────────────${RESET}"

    local version
    version=$(az bicep version 2>/dev/null | grep -oP '\d+\.\d+(\.\d+)?' | head -1 || echo "0.0")

    if [[ "$version" == "0.0" ]] || [[ -z "$version" ]]; then
        warn "Bicep CLI not detected. Install: az bicep install"
        warn "Bicep is only needed for script 1 (deployment). Continuing..."
        return 0
    fi

    if semver_gte "$version" "${min_major}.${min_minor}"; then
        ok "Bicep ${version} (minimum ${min_major}.${min_minor})"
    else
        fail "Bicep ${version} is below minimum ${min_major}.${min_minor}"
        echo "     Upgrade: az bicep upgrade"
        return 1
    fi
}

# =============================================================================
# validate_azure_auth
#   Confirms the caller is authenticated to Azure CLI.
#   Sets globals: SUBSCRIPTION_NAME, SUBSCRIPTION_ID, TENANT_ID
# =============================================================================
validate_azure_auth() {
    echo ""
    echo "${BOLD}─── Azure authentication check ─────────────────────────────${RESET}"

    if ! az account show --output none 2>/dev/null; then
        fail "Not logged in to Azure CLI."
        echo ""
        echo "     Authenticate first:"
        echo "       az login                      # interactive (browser)"
        echo "       az login --use-device-code    # headless / SSH"
        echo "       az account set --subscription <id or name>"
        return 1
    fi

    SUBSCRIPTION_NAME=$(az account show --query name -o tsv)
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    TENANT_ID=$(az account show --query tenantId -o tsv)

    ok "Logged in"
    echo "     Subscription : ${SUBSCRIPTION_NAME}"
    echo "     ID           : ${SUBSCRIPTION_ID}"
    echo "     Tenant       : ${TENANT_ID}"
}

# =============================================================================
# validate_resource_group <rg>
#   Confirms the resource group exists.
# =============================================================================
validate_resource_group() {
    local rg=$1
    echo ""
    echo "${BOLD}─── Resource group check ───────────────────────────────────${RESET}"

    if az group show --name "$rg" --output none 2>/dev/null; then
        ok "Resource group '${rg}' exists"
    else
        fail "Resource group '${rg}' not found."
        echo "     Create it: az group create --name '$rg' --location <region>"
        return 1
    fi
}

# =============================================================================
# validate_gateway_exists <gwName> <rg>
#   Confirms the ExpressRoute gateway resource is present.
# =============================================================================
validate_gateway_exists() {
    local gwName=$1 rg=$2
    echo ""
    echo "${BOLD}─── Gateway existence check ────────────────────────────────${RESET}"

    if az network vnet-gateway show --name "$gwName" --resource-group "$rg" --output none 2>/dev/null; then
        ok "Gateway '${gwName}' found in '${rg}'"
    else
        fail "Gateway '${gwName}' not found in resource group '${rg}'."
        echo "     List gateways: az network vnet-gateway list -g $rg -o table"
        return 1
    fi
}

# =============================================================================
# validate_gateway_state <gwName> <rg>
#   Confirms the gateway provisioningState is 'Succeeded'.
# =============================================================================
validate_gateway_state() {
    local gwName=$1 rg=$2
    echo ""
    echo "${BOLD}─── Gateway provisioning state check ───────────────────────${RESET}"

    local state
    state=$(az network vnet-gateway show \
        --name "$gwName" --resource-group "$rg" \
        --query "provisioningState" -o tsv 2>/dev/null || echo "Unknown")

    if [[ "$state" == "Succeeded" ]]; then
        ok "Gateway '${gwName}' provisioningState: Succeeded"
    else
        fail "Gateway '${gwName}' provisioningState: ${state} (expected Succeeded)"
        echo "     Tip: Wait for the current operation to complete before proceeding."
        return 1
    fi
}

# =============================================================================
# validate_gateway_sku_for_inplace_upgrade <gwName> <rg>
#   Confirms the gateway is on an AZ-enabled SKU (Scenario 1 prerequisite).
#   Allowed source SKUs: ErGw1AZ, ErGw2AZ, ErGw3AZ
# =============================================================================
validate_gateway_sku_for_inplace_upgrade() {
    local gwName=$1 rg=$2
    echo ""
    echo "${BOLD}─── Gateway SKU eligibility (in-place upgrade) ─────────────${RESET}"

    local sku
    sku=$(az network vnet-gateway show \
        --name "$gwName" --resource-group "$rg" \
        --query "sku.name" -o tsv 2>/dev/null || echo "Unknown")

    case "$sku" in
        ErGw1AZ|ErGw2AZ|ErGw3AZ)
            ok "Current SKU '${sku}' is eligible for in-place upgrade to ErGwScale"
            ;;
        ErGwScale)
            fail "Gateway '${gwName}' is already on ErGwScale — no upgrade needed."
            return 1
            ;;
        Standard|HighPerf|UltraPerf)
            fail "SKU '${sku}' is a non-AZ legacy SKU. In-place upgrade is NOT supported."
            echo "     Use Scenario 2 (Gateway Migration) instead."
            echo "     Docs: https://learn.microsoft.com/azure/expressroute/expressroute-howto-gateway-migration-portal"
            return 1
            ;;
        *)
            fail "Unknown SKU '${sku}'. Cannot confirm upgrade eligibility."
            return 1
            ;;
    esac
}

# =============================================================================
# validate_gateway_sku_for_migration <gwName> <rg>
#   Confirms gateway is eligible for the migration path (any non-ErGwScale SKU).
# =============================================================================
validate_gateway_sku_for_migration() {
    local gwName=$1 rg=$2
    echo ""
    echo "${BOLD}─── Gateway SKU eligibility (migration) ────────────────────${RESET}"

    local sku
    sku=$(az network vnet-gateway show \
        --name "$gwName" --resource-group "$rg" \
        --query "sku.name" -o tsv 2>/dev/null || echo "Unknown")

    case "$sku" in
        ErGwScale)
            fail "Gateway '${gwName}' is already on ErGwScale — no migration needed."
            return 1
            ;;
        ErGw1AZ|ErGw2AZ|ErGw3AZ|Standard|HighPerf|UltraPerf)
            ok "Current SKU '${sku}' is eligible for gateway migration to ErGwScale"
            if [[ "$sku" == "Standard" || "$sku" == "HighPerf" || "$sku" == "UltraPerf" ]]; then
                warn "Legacy non-AZ SKU '${sku}' detected. Migration is the only supported path."
            fi
            ;;
        *)
            fail "Unknown SKU '${sku}'. Cannot confirm migration eligibility."
            return 1
            ;;
    esac
}

# =============================================================================
# validate_gateway_subnet_size <vnetName> <rg>
#   Confirms the GatewaySubnet is at least /26 (required for ErGwScale).
#   Parses the prefix length from the subnet address prefix.
# =============================================================================
validate_gateway_subnet_size() {
    local vnetName=$1 rg=$2
    echo ""
    echo "${BOLD}─── GatewaySubnet size check (/26 minimum for ErGwScale) ───${RESET}"

    local prefix
    prefix=$(az network vnet subnet show \
        --vnet-name "$vnetName" \
        --name "GatewaySubnet" \
        --resource-group "$rg" \
        --query "addressPrefix" -o tsv 2>/dev/null || echo "")

    if [[ -z "$prefix" ]]; then
        fail "GatewaySubnet not found in VNet '${vnetName}'. Verify the VNet name."
        return 1
    fi

    local prefix_len
    prefix_len=$(echo "$prefix" | cut -d/ -f2)

    if (( prefix_len <= 26 )); then
        ok "GatewaySubnet: ${prefix}  (prefix /${prefix_len} ≤ /26 — sufficient for ErGwScale)"
    else
        fail "GatewaySubnet: ${prefix}  (prefix /${prefix_len} is too small — ErGwScale requires /26 or larger)"
        echo "     Resize the subnet before proceeding."
        echo "     Docs: https://learn.microsoft.com/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings#resize-a-gateway-subnet"
        return 1
    fi
}

# =============================================================================
# validate_er_circuit_state <circuitName> <rg>
#   Checks the ER circuit exists and the provider has provisioned it.
# =============================================================================
validate_er_circuit_state() {
    local circuitName=$1 rg=$2
    echo ""
    echo "${BOLD}─── ExpressRoute circuit state check ───────────────────────${RESET}"

    local circuitState
    circuitState=$(az network express-route show \
        --name "$circuitName" --resource-group "$rg" \
        --query "{circuit:circuitProvisioningState, provider:serviceProviderProvisioningState}" \
        -o json 2>/dev/null || echo "{}")

    local circuit provider
    circuit=$(echo "$circuitState" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('circuit','Unknown'))" 2>/dev/null || echo "Unknown")
    provider=$(echo "$circuitState" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('provider','Unknown'))" 2>/dev/null || echo "Unknown")

    echo "     Circuit provisioning state:  ${circuit}"
    echo "     Provider provisioning state: ${provider}"

    if [[ "$circuit" == "Enabled" && "$provider" == "Provisioned" ]]; then
        ok "ExpressRoute circuit '${circuitName}' is fully provisioned"
    elif [[ "$circuit" == "Enabled" && "$provider" != "Provisioned" ]]; then
        warn "Provider not yet provisioned (${provider}). Connectivity test will fail until the provider completes."
    else
        fail "Circuit '${circuitName}' is not in the expected Enabled/Provisioned state."
        return 1
    fi
}

# =============================================================================
# validate_no_active_migration <gwName> <rg>
#   Checks the gateway is not already undergoing a migration operation.
# =============================================================================
validate_no_active_migration() {
    local gwName=$1 rg=$2
    echo ""
    echo "${BOLD}─── Active migration check ─────────────────────────────────${RESET}"

    local state
    state=$(az network vnet-gateway show \
        --name "$gwName" --resource-group "$rg" \
        --query "provisioningState" -o tsv 2>/dev/null || echo "Unknown")

    if [[ "$state" == "Migrating" || "$state" == "Updating" ]]; then
        fail "Gateway '${gwName}' is already in state '${state}'."
        echo "     Wait for the operation to complete before starting a new migration."
        return 1
    fi
    ok "Gateway '${gwName}' has no active migration (state: ${state})"
}

# =============================================================================
# validate_er_connections <rg>
#   Lists all ER connections in the resource group and checks their state.
# =============================================================================
validate_er_connections() {
    local rg=$1
    echo ""
    echo "${BOLD}─── ExpressRoute connections check ─────────────────────────${RESET}"

    local connections
    connections=$(az network vpn-connection list --resource-group "$rg" \
        --query "[?connectionType=='ExpressRoute'].{Name:name, State:connectionStatus, Provisioning:provisioningState}" \
        -o json 2>/dev/null || echo "[]")

    local count
    count=$(echo "$connections" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [[ "$count" -eq 0 ]]; then
        warn "No ExpressRoute connections found in resource group '${rg}'."
        warn "Connectivity tests will fail until the ER connection is established."
        return 0
    fi

    echo "$connections" | python3 -c "
import sys, json
conns = json.load(sys.stdin)
for c in conns:
    name  = c.get('Name', 'N/A')
    state = c.get('State', 'N/A')
    prov  = c.get('Provisioning', 'N/A')
    print(f'     {name}  |  status={state}  |  provisioning={prov}')
" 2>/dev/null

    ok "${count} ER connection(s) found"
}

# =============================================================================
# print_validation_header <title>
# =============================================================================
print_validation_header() {
    echo ""
    echo "============================================================"
    echo "  PRE-FLIGHT VALIDATION: $1"
    echo "============================================================"
}

# =============================================================================
# print_validation_pass
# =============================================================================
print_validation_pass() {
    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}${BOLD}ALL PRE-FLIGHT CHECKS PASSED${RESET}"
    echo "============================================================"
    echo ""
}
