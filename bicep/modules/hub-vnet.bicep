// Hub VNet with subnets for ExpressRoute, Bastion, and VMs.

param location string
param hubName string
param addressSpacePrefix string
param subnet1Prefix string
param gatewaySubnetPrefix string
param bastionSubnetPrefix string

resource hubVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${hubName}-vnet'
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
      {
        // GatewaySubnet must be named exactly 'GatewaySubnet' — no NSG allowed
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: gatewaySubnetPrefix
        }
      }
      {
        // AzureBastionSubnet must be named exactly 'AzureBastionSubnet' — /26 or larger
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnetPrefix
        }
      }
    ]
  }
}

output vnetId string = hubVnet.id
output vnetName string = hubVnet.name
output subnet1Id string = '${hubVnet.id}/subnets/subnet1'
output gatewaySubnetId string = '${hubVnet.id}/subnets/GatewaySubnet'
output bastionSubnetId string = '${hubVnet.id}/subnets/AzureBastionSubnet'
