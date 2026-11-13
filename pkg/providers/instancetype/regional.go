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

package instancetype

import (
	"context"
	"strings"

	"github.com/Azure/skewer"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/karpenter/pkg/cloudprovider"

	"github.com/Azure/karpenter-provider-azure/pkg/apis/v1beta1"
	"github.com/Azure/karpenter-provider-azure/pkg/operator/options"
)

// RegionalProvider provides the instance types of the cluster location and, for node classes whose subnet is
// in an additional VNet (see options.AdditionalVNETs), the instance types of the location of that VNet.
type RegionalProvider struct {
	// the provider for the cluster location
	*DefaultProvider
	// the providers for other locations, keyed by lowercase location
	additional map[string]*DefaultProvider
}

// assert that RegionalProvider implements Provider interface
var _ Provider = (*RegionalProvider)(nil)

func NewRegionalProvider(clusterProvider *DefaultProvider, additional map[string]*DefaultProvider) *RegionalProvider {
	p := &RegionalProvider{DefaultProvider: clusterProvider, additional: map[string]*DefaultProvider{}}
	for location, provider := range additional {
		p.additional[strings.ToLower(location)] = provider
	}
	return p
}

func (p *RegionalProvider) List(ctx context.Context, nodeClass *v1beta1.AKSNodeClass) ([]*cloudprovider.InstanceType, error) {
	return p.forNodeClass(ctx, nodeClass).List(ctx, nodeClass)
}

// Get returns the SKU from the cluster location if it is offered there, otherwise from any other location.
// Callers only use what does not depend on the location: the name, family and capabilities.
func (p *RegionalProvider) Get(ctx context.Context, instanceType string) (*skewer.SKU, error) {
	sku, err := p.DefaultProvider.Get(ctx, instanceType)
	if err == nil {
		return sku, nil
	}
	for _, provider := range p.additional {
		if sku, additionalErr := provider.Get(ctx, instanceType); additionalErr == nil {
			return sku, nil
		}
	}
	return nil, err
}

// UpdateInstanceTypes only fails for the cluster location. A failure for another location leaves that
// location without instance types, or with the ones it had, until the next update.
func (p *RegionalProvider) UpdateInstanceTypes(ctx context.Context) error {
	for location, provider := range p.additional {
		if err := provider.UpdateInstanceTypes(ctx); err != nil {
			log.FromContext(ctx).Error(err, "updating instance types for additional location", "location", location)
		}
	}
	return p.DefaultProvider.UpdateInstanceTypes(ctx)
}

func (p *RegionalProvider) Reset() {
	p.DefaultProvider.Reset()
	for _, provider := range p.additional {
		provider.Reset()
	}
}

func (p *RegionalProvider) forNodeClass(ctx context.Context, nodeClass *v1beta1.AKSNodeClass) *DefaultProvider {
	location, _ := options.FromContext(ctx).AdditionalVNETLocationOfSubnetID(nodeClass.Spec.VNETSubnetID)
	if provider, ok := p.additional[strings.ToLower(location)]; ok {
		return provider
	}
	return p.DefaultProvider
}
