// Copyright 2025 The OpenChoreo Authors
// SPDX-License-Identifier: Apache-2.0

package clusterdataplane

import (
	"context"

	ctrl "sigs.k8s.io/controller-runtime"
)

// setupClusterDataPlaneRefIndex creates a field index for the clusterdataplane reference.
// Note: Cluster-scoped planes are typically not referenced by namespace-scoped resources like Environments.
// This is a placeholder for potential future needs.
func (r *Reconciler) setupClusterDataPlaneRefIndex(ctx context.Context, mgr ctrl.Manager) error {
	// No indexing needed for cluster-scoped resources as they don't watch namespace-scoped resources
	return nil
}
