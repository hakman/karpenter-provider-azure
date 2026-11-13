# Nodes in other regions through additional VNets

**Author:** @hakman

**Last updated:** November 13, 2026

**Status:** Experimental spike, written as a handover. Not proposed for merge as is.

## Goal

Extend one AKS cluster to other regions where quota and capacity exist. The cluster uses Azure CNI
Overlay with the Cilium dataplane. Karpenter creates the nodes as VMs in VNets that are peered with
the cluster VNet.

## Non-goals

- Another CNI, or a cluster per region.
- The AKS Machine API provision modes. AKS only creates machines in the cluster VNet.
- Deferred: load balancer backends and capacity reservation groups in the other regions.

## State

The work has two parts with different standing:

- **Karpenter changes.** They use supported APIs only and are tested. They could go upstream on
  their own.
- **Pod networking for nodes outside the cluster VNet.** It works, but through one mechanism that
  AKS does not support. Only AKS can make it unnecessary.

## Karpenter

- New option `--additional-vnets` (`ADDITIONAL_VNETS`): `vnetResourceID=location,...`. The VNets
  must be in the cluster subscription. Rejected with the AKS Machine API modes.
- An `AKSNodeClass` has one location, the one of the VNet of `spec.vnetSubnetID`.
- Fallback between regions is one NodePool per region, ordered by weight.
- Kept per location: instance types and zones, prices, quota, unavailable offerings, image
  versions and the bootstrap location. The existing single-location providers are instantiated
  once per location, and `instancetype.RegionalProvider` picks one by node class. Karpenter core
  is unchanged.
- In an additional VNet the NIC, VM and extensions are created in the VNet location, without the
  cluster load balancer backend pools and without the managed network security group.

| Area | Where |
|---|---|
| Option, validation | `pkg/operator/options/` |
| Per-location wiring | `pkg/operator/operator.go`, `pkg/test/environment.go` |
| Instance types | `pkg/providers/instancetype/regional.go` |
| Launch, quota records | `pkg/providers/instance/vminstance.go`, `quota.go` |
| Images, bootstrap | `pkg/providers/imagefamily/nodeimage.go`, `pkg/providers/launchtemplate/` |
| Tests | `pkg/providers/instancetype/suite_test.go`, context "Additional VNet in another location" |

## Network

- The user creates the VNets, the peering mesh, and a NAT gateway and network security group per
  VNet. See [`hack/azure/additional-vnets.bicep`](../hack/azure/additional-vnets.bicep).
- Pod traffic between VNets is carried by WireGuard, enabled the supported way through Advanced
  Container Networking Services. No route tables are used.
- **Unsupported:** a DaemonSet writes the CNI configuration on nodes outside the cluster VNet. See
  [`examples/v1/additional-vnet.yaml`](../examples/v1/additional-vnet.yaml).

Why the DaemonSet exists:

- The Azure host agent rejects NICs outside the cluster VNet
  (`401 ... OwningServiceInstanceId`), so `azure-cns` never configures the node and it stays
  NotReady.
- AKS still reserves a pod CIDR for the node in its `NodeNetworkConfig`, as long as the node
  carries the cluster VNet GUID label, which is what Karpenter sets today.
- The DaemonSet writes the same Cilium configuration AKS uses, with `host-local` IPAM for that
  pod CIDR.

## Limitations

Between different VNets:

- Nodes and host-network pods cannot reach pods, directly or through a Service.
- Services with `externalTrafficPolicy: Cluster` cannot forward to pods.
- DNS fails for pods on these nodes that are selected by a network policy with DNS rules.

## Verified

On a live cluster with nodes in three regions, on Kubernetes 1.36 and 1.37:

- Zonal nodes in two other regions, with correct labels, images and bootstrap location.
- Fallback to another region when a VM family has no quota left in the preferred one.
- Pod, Service, DNS, egress, `kubectl logs` and `exec`, and API server to pod traffic across regions.
- Graceful and crash reboots of a node: no leaked pod IPs.
- AKS upgrade from 1.36 to 1.37 (Cilium 1.19 to 1.20), then node replacement through drift.

## Discarded

- Per-node user-defined routes: do not scale.
- One route to a gateway node: single point of failure.
- Cilium node encryption (`encrypt-node`): lifts the limitations, but needs an unsupported edit to
  `cilium-config`, breaks bulk TCP between host networks, and is deprecated upstream.
- An AKS node pool in a peered subnet, and `OverlayExtensionConfig`: rejected or without effect.

## Open

1. **AKS support.** The DaemonSet goes away only if AKS programs the overlay for NICs in peered
   VNets. See [Azure/AKS#4408](https://github.com/Azure/AKS/issues/4408). The two blockers found
   are the host agent's 401 and the missing pod CIDR reservation for a node labelled with its own
   VNet GUID.
2. **Disturbance during node replacement.** Seen once: for about 90 seconds after two nodes in
   different regions were replaced together, a third of the requests between their pods failed.
   Not reproduced with a single new node. WireGuard peer churn is suspected.
3. **Bootstrap token.** An AKS upgrade rotates it. A self-hosted Karpenter keeps the old one, and
   new nodes do not join until it is redeployed. Not specific to this feature.
4. **Scale.** Not tested beyond seven nodes. Each node holds one WireGuard peer per other node, and
   the pod CIDR gives every node a `/24`.
5. **Simulated only.** `azure-cns` starting to work on such a node, and AKS changing a reserved pod
   CIDR. The DaemonSet handles both.
6. **Unit-tested only.** Capacity failures staying in their location, and the per-location image
   lookup.
7. **Still the cluster location.** Capacity recommendations, and the bootstrap data in
   `bootstrappingclient` mode, which AKS generates.
8. **Process.** No E2E suite, CI has not run, and the branch should be split into the Karpenter
   changes and the example.
