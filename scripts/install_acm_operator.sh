#!/bin/bash

set -e

# Required environment variables:
# - ACM_VERSION: Red Hat Advanced Cluster Management version (e.g., 2.14)
#
# The hub availability config (Basic/High) is auto-detected from the
# cluster topology: single-node OpenShift -> Basic, multi-node -> High.
#
# Based on the Red Hat documented CLI procedure (Installing from the
# OpenShift Container Platform CLI). Note that the Multicluster Engine
# operator does NOT need to be pre-installed: when the MultiClusterHub
# resource is created, the ACM operator automatically installs the
# multicluster engine operator and creates the MultiClusterEngine resource.
#
# https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.14/html/install/installing#installing-from-the-cli

CHANNEL=$(echo "${ACM_VERSION}" | cut -d. -f1-2)

# Resolve hub availability config from the cluster topology:
# Basic (1 replica) for single-node OpenShift, High (2 replicas) otherwise
NODES=$(oc get nodes --no-headers) || { echo "Error: failed to query cluster nodes" >&2; exit 1; }
NODE_COUNT=$(echo "${NODES}" | wc -l)
if [ "${NODE_COUNT}" -le 1 ]; then
    ACM_AVAILABILITY_CONFIG=Basic
else
    ACM_AVAILABILITY_CONFIG=High
fi
echo "Availability config: ${ACM_AVAILABILITY_CONFIG} (${NODE_COUNT} node(s))"

echo "Installing Red Hat Advanced Cluster Management Operator..."
echo "Channel: release-${CHANNEL}"

# Create namespace (with cluster-monitoring label, per Red Hat docs)
cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    openshift.io/cluster-monitoring: "true"
  name: open-cluster-management
EOF

# Create OperatorGroup
cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: open-cluster-management-operatorgroup
  namespace: open-cluster-management
spec:
  targetNamespaces:
  - open-cluster-management
EOF

# Create Subscription
cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: acm-operator-subscription
  namespace: open-cluster-management
spec:
  channel: release-${CHANNEL}
  installPlanApproval: Automatic
  name: advanced-cluster-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for the Subscription to resolve the operator CSV. The resolved CSV
# must belong to the requested channel (release-${CHANNEL}).
echo "Waiting for the ACM Operator Subscription to resolve (channel: release-${CHANNEL})..."
CSV_NAME=$(timeout 300s bash -c "
    until oc get subscription acm-operator-subscription -n open-cluster-management -o jsonpath='{.status.currentCSV}' 2>/dev/null | grep -q \"\.v${CHANNEL}\.\"; do
        sleep 10
    done
    oc get subscription acm-operator-subscription -n open-cluster-management -o jsonpath='{.status.currentCSV}'
") || { echo "Error: Subscription acm-operator-subscription did not resolve a CSV for release-${CHANNEL} within 300s" >&2; \
       echo "Subscription conditions:" >&2; \
       oc get subscription acm-operator-subscription -n open-cluster-management -o jsonpath='{.status.conditions}' >&2 || true; \
       exit 1; }

echo "Waiting for ACM Operator CSV to be created (CSV: ${CSV_NAME})..."
oc wait --for=create csv/${CSV_NAME} -n open-cluster-management --timeout=300s

echo "Waiting for ACM Operator to be ready (CSV: ${CSV_NAME})..."
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/${CSV_NAME} -n open-cluster-management --timeout=300s

echo "✔ ACM Operator installed"

# Create MultiClusterHub instance (hub cluster) required by the operator
echo "Creating MultiClusterHub instance..."

cat << EOF | oc apply -f -
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
spec:
  availabilityConfig: ${ACM_AVAILABILITY_CONFIG}
EOF

echo "Waiting for MultiClusterHub to be available (this also installs the"
echo "multicluster engine operator and creates the MultiClusterEngine)..."
oc wait --for=jsonpath='{.status.phase}'=Running multiclusterhub/multiclusterhub -n open-cluster-management --timeout=900s

echo "✔ MultiClusterHub is running"

CONSOLE_URL=$(oc -n openshift-console get route console -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [ -n "${CONSOLE_URL}" ]; then
    echo "Console URL: https://${CONSOLE_URL}"
fi

echo "ACM hub cluster components are running in the open-cluster-management namespace"
