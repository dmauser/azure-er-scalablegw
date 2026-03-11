#!/usr/bin/env bash
# =============================================================================
# Script 1 — Deploy Azure Infrastructure + ExpressRoute Circuit + Connection
# =============================================================================
# Usage: bash scripts/1-deploy-azure.azcli
#
# This script:
#   1. Deploys Hub+Spoke VNets, VMs (no public IP), Bastion, ER Gateway (ErGw1AZ)
#      (admin password is auto-generated inside Bicep and stored in Key Vault)
#   3. Creates the ExpressRoute Circuit (Megaport / Chicago)
#   4. Waits for provider provisioning (requires manual Megaport configuration)
#   5. Creates the ER connection between the circuit and the gateway
# =============================================================================

set -euo pipefail

# ─── Prompt for Resource Group and Region (with defaults) ────────────────────
echo ""
read -r -p "Resource Group name [lab-er-scale]: " rg_input
rg="${rg_input:-lab-er-scale}"

read -r -p "Azure region        [westus3]: " location_input
location="${location_input:-westus3}"

echo ""
echo "  Resource Group : $rg"
echo "  Azure Region   : $location"
echo ""

# ─── Parameters ──────────────────────────────────────────────────────────────
hubName=az-hub
spoke1Name=az-spk1
spoke2Name=az-spk2
adminUsername=azureuser
vmSize=Standard_DS1_v2

# ExpressRoute circuit settings
ername=er-lab-circuit     # ExpressRoute Circuit name

read -r -p "ER peering location [Dallas]: " cxlocation_input
cxlocation="${cxlocation_input:-Dallas}"

read -r -p "ER provider         [Megaport]: " provider_input
provider="${provider_input:-Megaport}"

echo ""
echo "  ER Peering Location : $cxlocation"
echo "  ER Provider         : $provider"
echo ""

# ─── Start Timer ────────────────────────────────────────────────────────────
start=$(date +%s)
echo "Script started at $(date)"

# ─── Detect Azure Cloud Shell and start keepalive ────────────────────────────
is_cloudshell=false
if [[ "${ACC_TERM:-}" == "1" ]] || [[ "${AZURE_HTTP_USER_AGENT:-}" == *"cloud-shell"* ]] || [[ "$(hostname)" == SandboxHost-* ]]; then
    is_cloudshell=true
fi

keepalive_pid=""
if $is_cloudshell; then
    echo "Azure Cloud Shell detected: starting keepalive to prevent timeout."
    (while true; do echo -e "\nCloud Shell keepalive\n"; sleep 300; done) &
    keepalive_pid=$!
fi

# ─── Get Deployer Object ID (for Key Vault access policy) ────────────────────
# The password is auto-generated inside Bicep and stored in Key Vault.
# We only need the deployer Object ID so the access policy is set correctly.
echo ""
echo "=== Retrieving deployer identity ==="
deployerObjectId=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || \
    az account show --query "user.name" -o tsv | xargs -I{} az ad user show --id {} --query id -o tsv)
echo "Deployer Object ID: $deployerObjectId"

# ─── Create Resource Group (idempotent) ──────────────────────────────────────
echo ""
echo "=== Ensuring resource group exists: $rg ==="
if az group show --name "$rg" --output none 2>/dev/null; then
    echo "Resource group already exists: $rg — skipping creation."
else
    az group create --name "$rg" --location "$location" --output none
    echo "Resource group created: $rg ($location)"
fi

# ─── Deploy Bicep Infrastructure (idempotent) ────────────────────────────────
echo ""
echo "=== Checking if Azure infrastructure is already deployed ==="

# Check for an existing ER Gateway in the resource group
existingGw=$(az network vnet-gateway list --resource-group "$rg" \
    --query "[?gatewayType=='ExpressRoute'].name" -o tsv 2>/dev/null || echo "")

if [[ -n "$existingGw" ]]; then
    echo "Infrastructure already deployed — skipping Bicep deployment."
    erGwName="$existingGw"
    kvName=$(az keyvault list --resource-group "$rg" --query '[0].name' -o tsv 2>/dev/null)
    echo "Key Vault:  $kvName"
    echo "ER Gateway: $erGwName"
else
    echo "=== Deploying Azure infrastructure ==="
    echo "    Hub + Spokes + VMs (no public IP) + Bastion + ER Gateway (ErGw1AZ)"
    echo "    This will take approximately 25-35 minutes (ER Gateway provisioning)..."
    echo ""

    deploymentOutputs=$(az deployment group create \
        --name "er-lab-deploy-$(date +%s)" \
        --resource-group "$rg" \
        --template-file "bicep/main.bicep" \
        --parameters "bicep/main.bicepparam" \
        --parameters \
            deployerObjectId="$deployerObjectId" \
            hubName="$hubName" \
            spoke1Name="$spoke1Name" \
            spoke2Name="$spoke2Name" \
            adminUsername="$adminUsername" \
            vmSize="$vmSize" \
        --query "properties.outputs" \
        --output json)

    echo ""
    echo "=== Bicep deployment complete ==="

    # Extract outputs
    kvName=$(echo "$deploymentOutputs" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['keyVaultName']['value'])")
    erGwName=$(echo "$deploymentOutputs" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['erGatewayName']['value'])")

    echo "Key Vault:            $kvName"
    echo "ER Gateway:           $erGwName"
    echo "Hub VM:               $(echo "$deploymentOutputs" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['hubVmName']['value'])")"
    echo "Spoke1 VM:            $(echo "$deploymentOutputs" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['spoke1VmName']['value'])")"
    echo "Spoke2 VM:            $(echo "$deploymentOutputs" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['spoke2VmName']['value'])")"
fi

# ─── Retrieve Admin Credentials from Key Vault ───────────────────────────────
echo ""
echo "=== Admin credentials stored in Key Vault ==="
echo "  Username: $(az keyvault secret show --vault-name "$kvName" --name admin-username --query value -o tsv 2>/dev/null || echo '(not accessible — check KV access policy)')"
echo "  Password: [retrieve with: az keyvault secret show --vault-name $kvName --name admin-password --query value -o tsv]"

# ─── Create ExpressRoute Circuit (idempotent) ────────────────────────────────
echo ""
echo "=== Ensuring ExpressRoute Circuit exists ==="

if az network express-route show -n "$ername" -g "$rg" --output none 2>/dev/null; then
    echo "ExpressRoute circuit '$ername' already exists — skipping creation."
else
    echo "    Provider:         $provider"
    echo "    Peering Location: $cxlocation"
    echo "    Bandwidth:        50 Mbps"
    echo "    SKU:              Standard / MeteredData"

    az network express-route create \
        --bandwidth 50 \
        --name "$ername" \
        --peering-location "$cxlocation" \
        --resource-group "$rg" \
        --provider "$provider" \
        --location "$location" \
        --sku-family MeteredData \
        --sku-tier Standard \
        --output none
    echo "ExpressRoute circuit '$ername' created."
fi

echo ""
echo "=== ExpressRoute Circuit service key ==="
serviceKey=$(az network express-route show -n "$ername" -g "$rg" --query serviceKey -o tsv)
echo "  Service Key: $serviceKey"
echo ""
echo "  *** ACTION REQUIRED ***"
echo "  Provide this service key to Megaport to provision the circuit."
echo "  See: https://docs.megaport.com/cloud/microsoft-azure/azure-expressroute/"
echo ""

# ─── Wait for Provider Provisioning ─────────────────────────────────────────
echo "=== Waiting for ExpressRoute provider provisioning ==="
echo "    Checking every 60 seconds... (this may take 15-60 minutes)"
echo "    Press Ctrl+C to exit — re-run this section manually when provider is ready."
echo ""

while true; do
    provState=$(az network express-route show -n "$ername" -g "$rg" \
        --query serviceProviderProvisioningState -o tsv)
    echo "$(date '+%H:%M:%S') Provider state: $provState"
    if [[ "$provState" == "Provisioned" ]]; then
        break
    fi
    sleep 60
done

echo ""
echo "=== Provider has provisioned the circuit ==="

# ─── Create ER Connection (idempotent) ───────────────────────────────────────
echo ""
echo "=== Ensuring ER connection exists ==="
connName="er-connection-${hubName}"

if az network vpn-connection show -n "$connName" -g "$rg" --output none 2>/dev/null; then
    echo "ER connection '$connName' already exists — skipping creation."
else
    echo "=== Creating ER connection: circuit → gateway ==="
    erid=$(az network express-route show -n "$ername" -g "$rg" --query id -o tsv)

    az network vpn-connection create \
        --name "$connName" \
        --resource-group "$rg" \
        --vnet-gateway1 "$erGwName" \
        --express-route-circuit2 "$erid" \
        --routing-weight 0 \
        --output none
    echo "ER connection '$connName' created."
fi

echo ""
echo "============================================================"
echo "  DEPLOYMENT COMPLETE"
echo "============================================================"
echo "  Resource Group:  $rg"
echo "  ER Gateway:      $erGwName  (SKU: ErGw1AZ)"
echo "  Key Vault:       $kvName"
echo ""
echo "  Next steps:"
echo "  1. Run: bash scripts/2-deploy-onprem-gcp.azcli  (GCP on-prem setup)"
echo "  2. Run: bash scripts/4-test-connectivity.sh      (verify baseline)"
echo "  3. Run: bash scripts/3-upgrade-ergw.azcli        (upgrade to ErGwScale)"
echo "============================================================"

# ─── Stop keepalive and print elapsed time ───────────────────────────────────
if $is_cloudshell && [[ -n "$keepalive_pid" ]]; then
    kill "$keepalive_pid" >/dev/null 2>&1
    echo "Stopped Cloud Shell keepalive process."
fi

end=$(date +%s)
runtime=$((end - start))
echo "Script finished at $(date)"
echo "Total execution time: $((runtime / 3600)) hours $(((runtime / 60) % 60)) minutes and $((runtime % 60)) seconds."
