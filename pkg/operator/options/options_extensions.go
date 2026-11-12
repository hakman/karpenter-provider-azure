/*
Portions Copyright (c) Microsoft Corporation.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package options

import (
	"strings"

	"github.com/Azure/karpenter-provider-azure/pkg/consts"
	"github.com/Azure/karpenter-provider-azure/pkg/utils"
)

func (o *Options) IsAzureCNIOverlay() bool {
	return o.NetworkPlugin == consts.NetworkPluginAzure && o.NetworkPluginMode == consts.NetworkPluginModeOverlay
}

func (o *Options) IsCiliumNodeSubnet() bool {
	return o.NetworkPlugin == consts.NetworkPluginAzure && o.NetworkPluginMode == consts.NetworkPluginModeNone && o.NetworkDataplane == consts.NetworkDataplaneCilium
}

func (o *Options) IsNetworkPluginNone() bool {
	return o.NetworkPlugin == consts.NetworkPluginNone
}

// AdditionalVNETGUID returns the resource GUID of the subnet's VNet, and true, if that VNet is listed in
// --additional-vnet-guids. The cluster VNet is never listed there (see validateAdditionalVNETGUIDs).
func (o *Options) AdditionalVNETGUID(subnet utils.VnetSubnetResource) (string, bool) {
	for vnetID, guid := range o.AdditionalVNETGUIDs {
		if strings.EqualFold(vnetID, subnet.VNetID()) {
			return guid, true
		}
	}
	return "", false
}

// SupportsWorkloadRuntime reports whether the configured provision mode can provision a non-default
// workloadRuntime (AKS Pod Sandboxing). The AKS machine API carries it on the machine object and the
// bootstrapping client carries it in the node bootstrapping request. The aksscriptless path builds
// custom data locally and has no way to install the Kata host stack.
func (o *Options) SupportsWorkloadRuntime() bool {
	return o.IsAKSMachineAPIMode() || o.ProvisionMode == consts.ProvisionModeBootstrappingClient
}

// SupportsNodePublicIP reports whether the configured provision mode can give nodes an
// instance-level public IP address. The AKS machine API carries it on the machine's network
// profile. The VM-based modes create NICs locally and don't attach a public IP.
func (o *Options) SupportsNodePublicIP() bool {
	return o.IsAKSMachineAPIMode()
}

// AdditionalVNETLocation returns the location of the subnet's VNet, and true, if one is set in
// --additional-vnet-locations.
func (o *Options) AdditionalVNETLocation(subnet utils.VnetSubnetResource) (string, bool) {
	for vnetID, location := range o.AdditionalVNETLocations {
		if strings.EqualFold(vnetID, subnet.VNetID()) {
			return location, true
		}
	}
	return "", false
}
