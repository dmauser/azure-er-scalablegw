targetScope = 'resourceGroup'

// ─── Parameters ──────────────────────────────────────────────────────────────

@description('Azure region for all resources.')
param location string = 'westus3'

@description('Hub VNet name prefix.')
param hubName string = 'az-hub'

@description('Spoke 1 VNet name prefix.')
param spoke1Name string = 'az-spk1'

@description('Spoke 2 VNet name prefix.')
param spoke2Name string = 'az-spk2'

@description('VM administrator username.')
param adminUsername string = 'azureuser'

@description('VM administrator password. Auto-generated per deployment if not supplied (newGuid). Stored securely in Key Vault — never output by this template.')
@secure()
param adminPassword string = newGuid()

@description('Virtual machine size.')
param vmSize string = 'Standard_DS1_v2'

@description('Object ID of the principal deploying this template. Used for Key Vault access policy. Omit to skip access policy (add manually later).')
param deployerObjectId string = ''

@description('Key Vault name. Must be globally unique, 3-24 alphanumeric/hyphen chars, starting with a letter.')
param kvName string = 'kv-er-${take(uniqueString(resourceGroup().id), 8)}'

@description('ExpressRoute Gateway SKU. Start with ErGw1AZ for the upgrade demo; use script 3 to upgrade to ErGwScale.')
@allowed(['ErGw1AZ', 'ErGw2AZ', 'ErGw3AZ', 'ErGwScale'])
param erGatewaySku string = 'ErGw1AZ'

// ─── Address Space ────────────────────────────────────────────────────────────

var hubAddressPrefix    = '10.0.0.0/24'
var hubSubnet1Prefix    = '10.0.0.0/27'
var hubGwSubnetPrefix   = '10.0.0.32/27'
var hubFwSubnetPrefix   = '10.0.0.64/26'
var hubRsSubnetPrefix   = '10.0.0.128/27'
var hubBastionPrefix    = '10.0.0.192/26'
var spoke1AddressPrefix = '10.0.1.0/24'
var spoke1Subnet1Prefix = '10.0.1.0/27'
var spoke2AddressPrefix = '10.0.2.0/24'
var spoke2Subnet1Prefix = '10.0.2.0/27'

// ─── Key Vault (deploy first — stores admin password) ────────────────────────

module kv 'modules/keyvault.bicep' = {
  name: 'deploy-keyvault'
  params: {
    location: location
    kvName: kvName
    adminUsername: adminUsername
    adminPassword: adminPassword
    deployerObjectId: deployerObjectId
  }
}


// ─── Virtual Networks ─────────────────────────────────────────────────────────

module hubVnet 'modules/hub-vnet.bicep' = {
  name: 'deploy-hub-vnet'
  params: {
    location: location
    hubName: hubName
    addressSpacePrefix: hubAddressPrefix
    subnet1Prefix: hubSubnet1Prefix
    gatewaySubnetPrefix: hubGwSubnetPrefix
    firewallSubnetPrefix: hubFwSubnetPrefix
    rsSubnetPrefix: hubRsSubnetPrefix
    bastionSubnetPrefix: hubBastionPrefix
  }
}

module spoke1Vnet 'modules/spoke-vnet.bicep' = {
  name: 'deploy-spoke1-vnet'
  params: {
    location: location
    spokeName: spoke1Name
    addressSpacePrefix: spoke1AddressPrefix
    subnet1Prefix: spoke1Subnet1Prefix
  }
}

module spoke2Vnet 'modules/spoke-vnet.bicep' = {
  name: 'deploy-spoke2-vnet'
  params: {
    location: location
    spokeName: spoke2Name
    addressSpacePrefix: spoke2AddressPrefix
    subnet1Prefix: spoke2Subnet1Prefix
  }
}

// ─── ExpressRoute Gateway ─────────────────────────────────────────────────────

module erGateway 'modules/er-gateway.bicep' = {
  name: 'deploy-er-gateway'
  params: {
    location: location
    gatewayName: '${hubName}-ergw'
    gatewaySubnetId: hubVnet.outputs.gatewaySubnetId
    gatewaySku: erGatewaySku
  }
}

// ─── Azure Bastion ────────────────────────────────────────────────────────────

module bastion 'modules/bastion.bicep' = {
  name: 'deploy-bastion'
  params: {
    location: location
    bastionName: '${hubName}-bastion'
    bastionSubnetId: hubVnet.outputs.bastionSubnetId
  }
}

// ─── Virtual Machines (no public IP, boot diagnostics for Serial Console) ────

module hubVm 'modules/vm.bicep' = {
  name: 'deploy-hub-vm'
  params: {
    location: location
    vmName: '${hubName}-vm'
    subnetId: hubVnet.outputs.subnet1Id
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
  }
}

module spoke1Vm 'modules/vm.bicep' = {
  name: 'deploy-spoke1-vm'
  params: {
    location: location
    vmName: '${spoke1Name}-vm'
    subnetId: spoke1Vnet.outputs.subnet1Id
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
  }
}

module spoke2Vm 'modules/vm.bicep' = {
  name: 'deploy-spoke2-vm'
  params: {
    location: location
    vmName: '${spoke2Name}-vm'
    subnetId: spoke2Vnet.outputs.subnet1Id
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
  }
}

// ─── VNet Peering: Hub ↔ Spoke1 ──────────────────────────────────────────────
// allowGatewayTransit=true on hub side, useRemoteGateways=true on spoke side
// Both depend on the ER gateway being fully provisioned

module peerHubToSpk1 'modules/vnet-peering.bicep' = {
  name: 'peer-hub-to-spk1'
  params: {
    localVnetName: hubVnet.outputs.vnetName
    remoteVnetId: spoke1Vnet.outputs.vnetId
    allowGatewayTransit: true
    useRemoteGateways: false
  }
  dependsOn: [erGateway]
}

module peerSpk1ToHub 'modules/vnet-peering.bicep' = {
  name: 'peer-spk1-to-hub'
  params: {
    localVnetName: spoke1Vnet.outputs.vnetName
    remoteVnetId: hubVnet.outputs.vnetId
    allowGatewayTransit: false
    useRemoteGateways: true
  }
  dependsOn: [erGateway, peerHubToSpk1]
}

// ─── VNet Peering: Hub ↔ Spoke2 ──────────────────────────────────────────────

module peerHubToSpk2 'modules/vnet-peering.bicep' = {
  name: 'peer-hub-to-spk2'
  params: {
    localVnetName: hubVnet.outputs.vnetName
    remoteVnetId: spoke2Vnet.outputs.vnetId
    allowGatewayTransit: true
    useRemoteGateways: false
  }
  dependsOn: [erGateway]
}

module peerSpk2ToHub 'modules/vnet-peering.bicep' = {
  name: 'peer-spk2-to-hub'
  params: {
    localVnetName: spoke2Vnet.outputs.vnetName
    remoteVnetId: hubVnet.outputs.vnetId
    allowGatewayTransit: false
    useRemoteGateways: true
  }
  dependsOn: [erGateway, peerHubToSpk2]
}

// ─── Outputs ──────────────────────────────────────────────────────────────────

output keyVaultName string = kv.outputs.kvName
// adminPasswordKvUri is the Key Vault URL to retrieve the password — not the password itself.
#disable-next-line outputs-should-not-contain-secrets
output adminPasswordKvUri string = kv.outputs.adminPasswordKvUri
output hubVnetId string = hubVnet.outputs.vnetId
output spoke1VnetId string = spoke1Vnet.outputs.vnetId
output spoke2VnetId string = spoke2Vnet.outputs.vnetId
output erGatewayId string = erGateway.outputs.gatewayId
output erGatewayName string = erGateway.outputs.gatewayName
output hubVmName string = hubVm.outputs.vmName
output spoke1VmName string = spoke1Vm.outputs.vmName
output spoke2VmName string = spoke2Vm.outputs.vmName
