// Azure Bastion (Basic SKU) for browser-based SSH/RDP access to VMs without public IPs.
// Requires AzureBastionSubnet (/26 or larger) in the hub VNet.

param location string
param bastionName string
param bastionSubnetId string

resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${bastionName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-09-01' = {
  name: bastionName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'IpConf'
        properties: {
          publicIPAddress: {
            id: bastionPip.id
          }
          subnet: {
            id: bastionSubnetId
          }
        }
      }
    ]
  }
}

output bastionId string = bastion.id
output bastionName string = bastion.name
output bastionPublicIp string = bastionPip.properties.ipAddress
