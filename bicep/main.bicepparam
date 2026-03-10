using './main.bicep'

// ─── Core Settings ────────────────────────────────────────────────────────────
param location = 'westus3'
param hubName   = 'az-hub'
param spoke1Name = 'az-spk1'
param spoke2Name = 'az-spk2'

// ─── VM Settings ─────────────────────────────────────────────────────────────
param adminUsername = 'azureuser'
param vmSize        = 'Standard_DS1_v2'

// ─── Gateway ─────────────────────────────────────────────────────────────────
// Start with ErGw1AZ; upgrade to ErGwScale using scripts/3-upgrade-ergw.azcli
param erGatewaySku = 'ErGw1AZ'

// ─── Auto-Generated Parameters (no assignment needed) ───────────────────────
// adminPassword    — auto-generated inside Bicep using uniqueString(); stored in Key Vault.
//                    Override via CLI: --parameters adminPassword='MyCustomPwd1!'
// deployerObjectId — optional; when provided, adds a Key Vault access policy for that principal.
//                    The deploy script (scripts/1-deploy-azure.azcli) sets this automatically.
