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

package instance

import (
	"context"
	"strings"

	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/controller-runtime/pkg/log"
	karpv1 "sigs.k8s.io/karpenter/pkg/apis/v1"

	"github.com/Azure/karpenter-provider-azure/pkg/apis/v1beta1"
	"github.com/Azure/karpenter-provider-azure/pkg/providers/instancetype"
	"github.com/Azure/karpenter-provider-azure/pkg/providers/quota"
)

// quotaMetadata is the immutable quota identity captured when a VM or AKS Machine create is
// accepted. Promises retain it so failed-create cleanup can undo the same quota adjustment.
type quotaMetadata struct {
	familyName string
	vCPUs      int64
	// location is where the quota is consumed. Empty means the cluster location.
	location string
	// eligible is true only for ordinary on-demand capacity. Spot and capacity-reservation-backed
	// instances set this to false
	eligible bool
}

// quotaLifecycle centralizes quota accounting shared by the VM and AKS Machine implementations.
// It keeps create, normal delete, and promise-cleanup behavior identical across provisioning modes.
type quotaLifecycle struct {
	provider             quota.Provider
	instanceTypeProvider instancetype.Provider
	// additional holds the providers for locations other than the cluster's, keyed by lowercase location
	additional map[string]quota.Provider
}

func newQuotaLifecycle(provider quota.Provider, instanceTypeProvider instancetype.Provider) *quotaLifecycle {
	return &quotaLifecycle{
		provider:             provider,
		instanceTypeProvider: instanceTypeProvider,
	}
}

// providerFor returns the quota provider for a location, which is the cluster's unless the location has its own.
func (q *quotaLifecycle) providerFor(location string) quota.Provider {
	if provider, ok := q.additional[strings.ToLower(location)]; ok {
		return provider
	}
	return q.provider
}

func (q *quotaLifecycle) snapshotGeneration() uint64 {
	return q.provider.SnapshotGeneration()
}

// recordCreate records an accepted create using the same immutable metadata retained by its promise.
func (q *quotaLifecycle) recordCreate(generation uint64, nodeClaim *karpv1.NodeClaim, metadata quotaMetadata) {
	if metadata.eligible {
		q.providerFor(metadata.location).RecordCreate(generation, nodeClaim, metadata.familyName, metadata.vCPUs)
	}
}

// recordDelete applies a confirmed deletion using launch metadata already held by a promise.
func (q *quotaLifecycle) recordDelete(nodeClaim *karpv1.NodeClaim, metadata quotaMetadata) {
	if metadata.eligible {
		q.providerFor(metadata.location).RecordDelete(nodeClaim, metadata.familyName, metadata.vCPUs)
	}
}

// recordDeleteFromNodeClaim reconstructs launch metadata for ordinary NodeClaim deletion after the
// original promise is gone. The CRG annotation preserves reservation eligibility across NodeClass changes.
func (q *quotaLifecycle) recordDeleteFromNodeClaim(ctx context.Context, nodeClaim *karpv1.NodeClaim) {
	if nodeClaim.Labels[karpv1.CapacityTypeLabelKey] != karpv1.CapacityTypeOnDemand {
		return
	}
	capacityReservationGroupID, ok := nodeClaim.Annotations[v1beta1.AnnotationCapacityReservationGroupID]
	if !ok {
		log.FromContext(ctx).V(1).Info("skipping quota delete adjustment, launch-time capacity reservation metadata is missing")
		return
	}
	metadata := q.metadata(ctx, nodeClaim.Labels[corev1.LabelInstanceTypeStable], karpv1.CapacityTypeOnDemand, capacityReservationGroupID != "")
	metadata.location = nodeClaim.Labels[corev1.LabelTopologyRegion]
	q.recordDelete(nodeClaim, metadata)
}

// metadata resolves the family and vCPU magnitude used by the shared quota provider.
func (q *quotaLifecycle) metadata(ctx context.Context, instanceType, capacityType string, reserved bool) quotaMetadata {
	if instanceType == "" || capacityType != karpv1.CapacityTypeOnDemand || reserved {
		return quotaMetadata{}
	}
	sku, err := q.instanceTypeProvider.Get(ctx, instanceType)
	if err != nil {
		log.FromContext(ctx).V(1).Info("skipping quota adjustment, failed to resolve instance type", "instanceType", instanceType, "error", err)
		return quotaMetadata{}
	}
	vCPUs, err := sku.VCPU()
	if err != nil || sku.GetFamilyName() == "" {
		log.FromContext(ctx).V(1).Info("skipping quota adjustment, failed to resolve SKU quota details", "instanceType", instanceType, "error", err)
		return quotaMetadata{}
	}
	return quotaMetadata{familyName: sku.GetFamilyName(), vCPUs: vCPUs, eligible: true}
}
