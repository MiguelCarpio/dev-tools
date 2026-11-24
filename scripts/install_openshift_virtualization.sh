#!/bin/bash

set -e

# Installs the OpenShift Virtualization operator (kubevirt-hyperconverged).
# The stable channel automatically selects the version matching the cluster.

echo "Installing OpenShift Virtualization Operator..."
echo "Channel: stable"

# Create namespace, OperatorGroup and Subscription
cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
  labels:
    openshift.io/cluster-monitoring: "true"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
  - openshift-cnv
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  channel: stable
  installPlanApproval: Automatic
  name: kubevirt-hyperconverged
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for the Subscription to resolve the operator CSV
echo "Waiting for the OpenShift Virtualization Operator Subscription to resolve..."
CSV_NAME=$(timeout 300s bash -c "
    until oc get subscription hco-operatorhub -n openshift-cnv -o jsonpath='{.status.currentCSV}' 2>/dev/null | grep -q .; do
        sleep 10
    done
    oc get subscription hco-operatorhub -n openshift-cnv -o jsonpath='{.status.currentCSV}'
") || { echo "Error: Subscription hco-operatorhub did not resolve a CSV within 300s" >&2; \
       echo "Subscription conditions:" >&2; \
       oc get subscription hco-operatorhub -n openshift-cnv -o jsonpath='{.status.conditions}' >&2 || true; \
       exit 1; }

echo "Waiting for OpenShift Virtualization Operator to be ready (CSV: ${CSV_NAME})..."
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/${CSV_NAME} -n openshift-cnv --timeout=300s

echo "✔ OpenShift Virtualization Operator installed"

# Create HyperConverged instance required by the operator
echo "Creating HyperConverged instance..."

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
