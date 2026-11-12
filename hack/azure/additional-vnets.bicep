// [EXPERIMENTAL] Additional VNets for Karpenter nodes outside the cluster VNet; see examples/v1/additional-vnet.yaml.
//
// Deploy to the resource group of the cluster VNet. For each additional VNet this creates a subnet with a
// NAT gateway, a network security group and a route table, and peers the VNet with the cluster VNet and
// with every other additional VNet.
//
// Not covered: enabling WireGuard on the cluster, and the per-node pod CIDR routes on the cluster subnet
// that host-to-pod and NodePort traffic into these VNets needs.

@description('Name of the cluster VNet, in this resource group')
param clusterVnetName string

@description('Additional VNets: name, location, addressPrefix (VNet) and subnetPrefix (node subnet)')
param vnets {
  name: string
  location: string
  addressPrefix: string
  subnetPrefix: string
}[]

@description('Pod CIDR of the cluster')
param podCidr string = '10.244.0.0/16'

@description('IP of a cluster VNet node (or internal load balancer in front of several) that forwards pod CIDR traffic from the additional VNets. Leave empty to rely on WireGuard for pod-to-pod traffic only.')
param podCidrGatewayIP string = ''

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

// The default rules cover node-to-node traffic, including WireGuard. Traffic routed to or from pod IPs
// needs explicit rules, because the pod CIDR is not part of the VirtualNetwork service tag.
resource securityGroups 'Microsoft.Network/networkSecurityGroups@2024-05-01' = [
  for vnet in vnets: {
    name: '${vnet.name}-nsg'
    location: vnet.location
    tags: tags
    properties: {
      securityRules: [
        {
          name: 'AllowFromPodCidrInbound'
          properties: {
            priority: 200
            direction: 'Inbound'
            access: 'Allow'
            protocol: '*'
            sourceAddressPrefix: podCidr
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '*'
          }
        }
        {
          name: 'AllowToPodCidrInbound'
          properties: {
            priority: 210
            direction: 'Inbound'
            access: 'Allow'
            protocol: '*'
            sourceAddressPrefix: 'VirtualNetwork'
            sourcePortRange: '*'
            destinationAddressPrefix: podCidr
            destinationPortRange: '*'
          }
        }
        {
          name: 'AllowToPodCidrOutbound'
          properties: {
            priority: 200
            direction: 'Outbound'
            access: 'Allow'
            protocol: '*'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: podCidr
            destinationPortRange: '*'
          }
        }
      ]
    }
  }
]

resource routeTables 'Microsoft.Network/routeTables@2024-05-01' = [
  for vnet in vnets: {
    name: '${vnet.name}-routes'
    location: vnet.location
    tags: tags
    properties: {
      routes: empty(podCidrGatewayIP)
        ? []
        : [
            {
              name: 'pod-cidr-via-gateway'
              properties: {
                addressPrefix: podCidr
                nextHopType: 'VirtualAppliance'
                nextHopIpAddress: podCidrGatewayIP
              }
            }
          ]
    }
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
            routeTable: { id: routeTables[i].id }
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
      allowForwardedTraffic: true
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
      allowForwardedTraffic: true
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
      allowForwardedTraffic: true
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
