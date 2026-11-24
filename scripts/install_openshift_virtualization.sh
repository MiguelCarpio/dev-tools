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

echo "Waiting for OpenShift Virtualization Operator CSV to be created..."
until oc get csv -n openshift-cnv -o name 2>/dev/null | grep -q .; do
    echo "  Waiting for operator CSV..."
    sleep 10
done

CSV_NAME=$(oc get csv -n openshift-cnv -o jsonpath='{.items[0].metadata.name}')
echo "Waiting for OpenShift Virtualization Operator to be ready (CSV: ${CSV_NAME})..."
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/${CSV_NAME} -n openshift-cnv --timeout=300s

echo "✔ OpenShift Virtualization Operator installed"
