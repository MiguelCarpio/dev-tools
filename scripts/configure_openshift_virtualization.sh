#!/bin/bash

set -e

echo "Creating HyperConverged instance..."

# Create HyperConverged CR (launches OpenShift Virtualization)
cat << EOF | oc apply -f -
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec: {}
EOF

echo "Waiting for HyperConverged to be available..."
oc wait --for=condition=Available hyperconverged/kubevirt-hyperconverged -n openshift-cnv --timeout=600s

echo "✔ HyperConverged is available"
echo "OpenShift Virtualization components are running in the openshift-cnv namespace"
