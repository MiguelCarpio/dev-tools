#!/bin/bash

set -e

# Required environment variables:
# - LVMS_DEVICES: Space-separated list of devices (e.g., "/dev/sdb /dev/sdc")
# - LVMS_DEVICE_CLASS: Device class name (default: openstack)

LVMS_DEVICE_CLASS="${LVMS_DEVICE_CLASS:-openstack}"
LVMS_CLUSTER_NAME="${LVMS_CLUSTER_NAME:-lvmcluster}"
LVMS_NAMESPACE="${LVMS_NAMESPACE:-openshift-storage}"

# Build deviceSelector optionalPaths YAML
DEVICE_PATHS=""
for dev in ${LVMS_DEVICES}; do
    DEVICE_PATHS="${DEVICE_PATHS}        - ${dev}
"
done
DEVICE_PATHS="${DEVICE_PATHS%
}"

echo "Creating/updating LVMCluster deviceClass: ${LVMS_DEVICE_CLASS}"
echo "Devices: ${LVMS_DEVICES}"
echo "StorageClass: lvms-${LVMS_DEVICE_CLASS}"

if oc get lvmcluster ${LVMS_CLUSTER_NAME} -n ${LVMS_NAMESPACE} &>/dev/null; then
    if oc get lvmcluster ${LVMS_CLUSTER_NAME} -n ${LVMS_NAMESPACE} \
        -o jsonpath="{.spec.storage.deviceClasses[?(@.name=='${LVMS_DEVICE_CLASS}')]}" | grep -q .; then
        echo "deviceClass ${LVMS_DEVICE_CLASS} already exists, nothing to add"
    else
        echo "LVMCluster already exists, adding deviceClass..."
        PATCH=$(cat <<EOFPATCH
[{
  "op": "add",
  "path": "/spec/storage/deviceClasses/-",
  "value": {
    "name": "${LVMS_DEVICE_CLASS}",
    "thinPoolConfig": {
      "name": "thin-pool-${LVMS_DEVICE_CLASS}",
      "sizePercent": 90,
      "overprovisionRatio": 10
    },
    "deviceSelector": {
      "optionalPaths": [$(echo ${LVMS_DEVICES} | sed 's|[^ ]*|"&"|g' | sed 's| |, |g')]
    }
  }
}]
EOFPATCH
)
        oc patch lvmcluster ${LVMS_CLUSTER_NAME} -n ${LVMS_NAMESPACE} --type=json -p "${PATCH}"
    fi
else
    echo "Creating new LVMCluster..."
    cat << EOF | oc apply -f -
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: ${LVMS_CLUSTER_NAME}
  namespace: ${LVMS_NAMESPACE}
spec:
  storage:
    deviceClasses:
    - name: ${LVMS_DEVICE_CLASS}
      thinPoolConfig:
        name: thin-pool-${LVMS_DEVICE_CLASS}
        sizePercent: 90
        overprovisionRatio: 10
      deviceSelector:
        optionalPaths:
${DEVICE_PATHS}
EOF
fi

echo "Waiting for LVMCluster to be ready..."
oc wait --for=jsonpath='{.status.ready}'=true lvmcluster/${LVMS_CLUSTER_NAME} -n ${LVMS_NAMESPACE} --timeout=600s

echo "Waiting for StorageClass lvms-${LVMS_DEVICE_CLASS} to be created..."
timeout 300s bash -c "
    until oc get storageclass lvms-${LVMS_DEVICE_CLASS} &>/dev/null; do
        sleep 10
    done
" || { echo "Error: StorageClass lvms-${LVMS_DEVICE_CLASS} was not created within 300s" >&2; \
       exit 1; }

echo "✔ LVMCluster ready with deviceClass: ${LVMS_DEVICE_CLASS}"
echo ""
echo "StorageClass created: lvms-${LVMS_DEVICE_CLASS}"
oc get storageclass lvms-${LVMS_DEVICE_CLASS}
