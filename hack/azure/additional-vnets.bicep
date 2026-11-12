// [EXPERIMENTAL] Additional VNets for Karpenter nodes outside the cluster VNet; see examples/v1/additional-vnet.yaml.
//
// Deploy to the resource group of the cluster VNet. For each additional VNet this creates a subnet with a
// NAT gateway and a network security group, and peers the VNet with the cluster VNet and with every other
// additional VNet.
//
// This is all the network needs when WireGuard with node encryption carries the traffic between nodes,
// as described in the example: Azure then only sees traffic between node IPs. Enabling that on the
// cluster is not covered here.

@description('Name of the cluster VNet, in this resource group')
param clusterVnetName string

@description('Additional VNets: name, location, addressPrefix (VNet) and subnetPrefix (node subnet)')
param vnets {
  name: string
  location: string
  addressPrefix: string
  subnetPrefix: string
}[]

@description('Principal ID of the Karpenter identity; gets Network Contributor on the additional VNets. Leave empty to skip.')
param karpenterPrincipalId string = ''

param subnetName string = 'nodes'
param tags object = {}

var networkContributorRoleId = '4d97b98b-1d4f-4787-a291-c67834d212e7'

// every ordered pair of additional VNets, for the peering mesh
var vnetPairs = flatten(map(
  range(0, length(vnets)),
  i => map(filter(range(0, length(vnets)), j => j != i), j => { from: vnets[i].name, to: vnets[j].name })
))

resource clusterVnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: clusterVnetName
}

resource publicIPs 'Microsoft.Network/publicIPAddresses@2024-05-01' = [
  for vnet in vnets: {
    name: '${vnet.name}-natgw-pip'
    location: vnet.location
    tags: tags
    sku: { name: 'Standard' }
    properties: { publicIPAllocationMethod: 'Static' }
  }
]

resource natGateways 'Microsoft.Network/natGateways@2024-05-01' = [
  for (vnet, i) in vnets: {
    name: '${vnet.name}-natgw'
    location: vnet.location
    tags: tags
    sku: { name: 'Standard' }
    properties: { publicIpAddresses: [{ id: publicIPs[i].id }] }
  }
]

// The default rules allow traffic between the node IPs of peered VNets, which is all WireGuard needs.
resource securityGroups 'Microsoft.Network/networkSecurityGroups@2024-05-01' = [
  for vnet in vnets: {
    name: '${vnet.name}-nsg'
    location: vnet.location
    tags: tags
  }
]

resource additionalVnets 'Microsoft.Network/virtualNetworks@2024-05-01' = [
  for (vnet, i) in vnets: {
    name: vnet.name
    location: vnet.location
    tags: tags
    properties: {
      addressSpace: { addressPrefixes: [vnet.addressPrefix] }
      subnets: [
        {
          name: subnetName
          properties: {
            addressPrefix: vnet.subnetPrefix
            natGateway: { id: natGateways[i].id }
            networkSecurityGroup: { id: securityGroups[i].id }
          }
        }
      ]
    }
  }
]

// Peerings on the same VNet must not be written concurrently, hence the batch size and dependency chain.
@batchSize(1)
resource peeringsFromCluster 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = [
  for (vnet, i) in vnets: {
    parent: clusterVnet
    name: 'to-${vnet.name}'
    properties: {
      remoteVirtualNetwork: { id: additionalVnets[i].id }
      allowVirtualNetworkAccess: true
    }
  }
]

@batchSize(1)
resource peeringsToCluster 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = [
  for (vnet, i) in vnets: {
    parent: additionalVnets[i]
    name: 'to-${clusterVnetName}'
    properties: {
      remoteVirtualNetwork: { id: clusterVnet.id }
      allowVirtualNetworkAccess: true
    }
    dependsOn: [peeringsFromCluster]
  }
]

@batchSize(1)
resource peeringsMesh 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = [
  for pair in vnetPairs: {
    name: '${pair.from}/to-${pair.to}'
    properties: {
      remoteVirtualNetwork: { id: resourceId('Microsoft.Network/virtualNetworks', pair.to) }
      allowVirtualNetworkAccess: true
    }
    dependsOn: [peeringsToCluster]
  }
]

resource roleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (vnet, i) in vnets: if (!empty(karpenterPrincipalId)) {
    scope: additionalVnets[i]
    name: guid(additionalVnets[i].id, karpenterPrincipalId, networkContributorRoleId)
    properties: {
      principalId: karpenterPrincipalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', networkContributorRoleId)
    }
  }
]

@description('Value for the Karpenter --additional-vnets option (ADDITIONAL_VNETS)')
output additionalVnets string = join(
  map(vnets, vnet => '${resourceId('Microsoft.Network/virtualNetworks', vnet.name)}=${vnet.location}'),
  ','
)

@description('Values for AKSNodeClass.spec.vnetSubnetID')
output subnetIDs array = [for (vnet, i) in vnets: '${additionalVnets[i].id}/subnets/${subnetName}']
