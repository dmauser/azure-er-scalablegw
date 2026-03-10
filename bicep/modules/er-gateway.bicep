// ExpressRoute Gateway module.
// Default SKU is ErGw1AZ (zone-redundant, 1 Gbps) — designed to be upgraded to ErGwScale.
// The Public IP uses Standard SKU with zone redundancy to match the gateway.
// To upgrade in-place: re-deploy with gatewaySku = 'ErGwScale' or use script 3.

param location string
param gatewayName string
param gatewaySubnetId string

@allowed(['ErGw1AZ', 'ErGw2AZ', 'ErGw3AZ', 'ErGwScale'])
param gatewaySku string = 'ErGw1AZ'

resource erGwPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${gatewayName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  zones: [
    '1'
    '2'
    '3'
  ]
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource erGateway 'Microsoft.Network/virtualNetworkGateways@2023-09-01' = {
  name: gatewayName
  location: location
  properties: {
    gatewayType: 'ExpressRoute'
    sku: {
      name: gatewaySku
      tier: gatewaySku
    }
    ipConfigurations: [
      {
        name: 'GatewayIpConfig'
        properties: {
          publicIPAddress: {
            id: erGwPip.id
          }
          subnet: {
            id: gatewaySubnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

output gatewayId string = erGateway.id
output gatewayName string = erGateway.name
output gatewayPublicIp string = erGwPip.properties.ipAddress
output gatewaySku string = erGateway.properties.sku.name
