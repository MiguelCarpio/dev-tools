#!/bin/bash

set -e

# Required environment variables:
# - MCE_VERSION: MultiCluster Engine version (e.g., 2.5)
#
# Based on the Red Hat documented CLI procedure:
# https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.5/html-single/multicluster-engine/index#installing-from-the-cli

CHANNEL=$(echo "${MCE_VERSION}" | cut -d. -f1-2)

echo "Installing MultiCluster Engine Operator..."
echo "Channel: stable-${CHANNEL}"

# Create namespace (with cluster-monitoring label, per Red Hat docs)
cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    openshift.io/cluster-monitoring: "true"
  name: multicluster-engine
EOF

# Create OperatorGroup
cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: multicluster-engine-operatorgroup
  namespace: multicluster-engine
spec:
  targetNamespaces:
  - multicluster-engine
EOF

# Create Subscription
cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: multicluster-engine
  namespace: multicluster-engine
spec:
  channel: stable-${CHANNEL}
  installPlanApproval: Automatic
  name: multicluster-engine
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for MultiCluster Engine Operator CSV to be created..."
until oc get csv -n multicluster-engine -o name 2>/dev/null | grep -q .; do
    echo "  Waiting for operator CSV..."
    sleep 10
done

CSV_NAME=$(oc get csv -n multicluster-engine -o jsonpath='{.items[0].metadata.name}')
echo "Waiting for MultiCluster Engine Operator to be ready (CSV: ${CSV_NAME})..."
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/${CSV_NAME} -n multicluster-engine --timeout=300s

echo "✔ MultiCluster Engine Operator installed"
