#!/bin/bash

set -e

echo "Creating MultiClusterEngine instance..."

# Create MultiClusterEngine CR (hub cluster)
cat << EOF | oc apply -f -
apiVersion: multicluster.openshift.io/v1
kind: MultiClusterEngine
metadata:
  name: multicluster-engine
spec: {}
EOF

echo "Waiting for MultiClusterEngine to be available..."
oc wait --for=condition=Available multiclusterengine/multicluster-engine --timeout=600s

echo "✔ MultiClusterEngine is available"
echo "Hub cluster components (Hive, HyperShift, central infrastructure management) are deploying in the multicluster-engine namespace"
