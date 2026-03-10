// Creates a single-direction VNet peering from localVnet → remoteVnet.
// Call this module twice (both directions) for a complete peering.
// allowGatewayTransit should be true on the hub side.
// useRemoteGateways should be true on the spoke side.

param localVnetName string
param remoteVnetId string
param allowGatewayTransit bool = false
param useRemoteGateways bool = false

var remoteVnetName = last(split(remoteVnetId, '/'))
var peeringName = 'peer-to-${remoteVnetName}'

resource localVnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: localVnetName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: localVnet
  name: peeringName
  properties: {
    remoteVirtualNetwork: {
      id: remoteVnetId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: allowGatewayTransit
    useRemoteGateways: useRemoteGateways
  }
}

output peeringId string = peering.id
output peeringName string = peering.name
