// Reusable Spoke VNet module. Deploys a single VNet with one workload subnet.

param location string
param spokeName string
param addressSpacePrefix string
param subnet1Prefix string

resource spokeVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${spokeName}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [addressSpacePrefix]
    }
    subnets: [
      {
        name: 'subnet1'
        properties: {
          addressPrefix: subnet1Prefix
        }
      }
    ]
  }
}

output vnetId string = spokeVnet.id
output vnetName string = spokeVnet.name
output subnet1Id string = '${spokeVnet.id}/subnets/subnet1'
