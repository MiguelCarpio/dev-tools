#!/bin/bash

set -e

# Required environment variables (no defaults; see configs/sno.example.sh):
# - LVMS_DEVICES: Space-separated list of devices (e.g., "/dev/sdb /dev/sdc")
# - LVMS_DEVICE_CLASS_NAME: Device class name

# Build deviceSelector optionalPaths YAML
DEVICE_PATHS=""
for dev in ${LVMS_DEVICES}; do
    DEVICE_PATHS="${DEVICE_PATHS}        - ${dev}
"
done
DEVICE_PATHS="${DEVICE_PATHS%
}"

echo "Creating/updating LVMCluster deviceClass: ${LVMS_DEVICE_CLASS_NAME}"
echo "Devices: ${LVMS_DEVICES}"
echo "StorageClass: lvms-${LVMS_DEVICE_CLASS_NAME}"

if oc get lvmcluster lvmcluster -n openshift-storage &>/dev/null; then
    if oc get lvmcluster lvmcluster -n openshift-storage \
        -o jsonpath="{.spec.storage.deviceClasses[?(@.name=='${LVMS_DEVICE_CLASS_NAME}')]}" | grep -q .; then
        # deviceClass exists: merge LVMS_DEVICES into its optionalPaths
        # (union with the current devices, no duplicates)
        CURRENT_PATHS=$(oc get lvmcluster lvmcluster -n openshift-storage \
            -o jsonpath="{range .spec.storage.deviceClasses[?(@.name=='${LVMS_DEVICE_CLASS_NAME}')].deviceSelector.optionalPaths[*]}{.}{\"\\n\"}{end}" \
            | tr '\n' ' ')
        MERGED_PATHS=""
        for dev in ${CURRENT_PATHS} ${LVMS_DEVICES}; do
            case " ${MERGED_PATHS} " in
                *" ${dev} "*) ;; # already included
                *) MERGED_PATHS="${MERGED_PATHS:+${MERGED_PATHS} }${dev}" ;;
            esac
        done
        if [ "$(echo ${CURRENT_PATHS})" = "${MERGED_PATHS}" ]; then
            echo "deviceClass ${LVMS_DEVICE_CLASS_NAME}: devices already configured, nothing to change"
        else
        JSON_PATHS=$(echo ${MERGED_PATHS} | sed 's|[^ ]*|"&"|g' | sed 's| |, |g')
        # Resolve the deviceClass array index (it may not be the first entry)
        DC_INDEX=$(oc get lvmcluster lvmcluster -n openshift-storage \
            -o jsonpath='{.spec.storage.deviceClasses[*].name}' | tr ' ' '\n' \
            | grep -n "^${LVMS_DEVICE_CLASS_NAME}$" | head -1 | cut -d: -f1)
        if [ -z "${DC_INDEX}" ]; then
            echo "Error: could not resolve index of deviceClass ${LVMS_DEVICE_CLASS_NAME}" >&2
            exit 1
        fi
        DC_INDEX=$((DC_INDEX - 1))
        echo "deviceClass ${LVMS_DEVICE_CLASS_NAME} already exists, updating devices: ${MERGED_PATHS}"
        PATCH=$(cat <<EOFPATCH
[{
  "op": "add",
  "path": "/spec/storage/deviceClasses/${DC_INDEX}/deviceSelector/optionalPaths",
  "value": [${JSON_PATHS}]
}]
EOFPATCH
)
        oc patch lvmcluster lvmcluster -n openshift-storage --type=json -p "${PATCH}"
        fi
    else
        echo "LVMCluster already exists, adding deviceClass..."
        PATCH=$(cat <<EOFPATCH
[{
  "op": "add",
  "path": "/spec/storage/deviceClasses/-",
  "value": {
    "name": "${LVMS_DEVICE_CLASS_NAME}",
    "thinPoolConfig": {
      "name": "thin-pool-${LVMS_DEVICE_CLASS_NAME}",
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
        oc patch lvmcluster lvmcluster -n openshift-storage --type=json -p "${PATCH}"
    fi
else
    echo "Creating new LVMCluster..."
    cat << EOF | oc apply -f -
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: lvmcluster
  namespace: openshift-storage
spec:
  storage:
    deviceClasses:
    - name: ${LVMS_DEVICE_CLASS_NAME}
      thinPoolConfig:
        name: thin-pool-${LVMS_DEVICE_CLASS_NAME}
        sizePercent: 90
        overprovisionRatio: 10
      deviceSelector:
        optionalPaths:
${DEVICE_PATHS}
EOF
fi

echo "Waiting for LVMCluster to be ready..."
oc wait --for=jsonpath='{.status.ready}'=true lvmcluster/lvmcluster -n openshift-storage --timeout=600s

echo "Waiting for StorageClass lvms-${LVMS_DEVICE_CLASS_NAME} to be created..."
timeout 300s bash -c "
    until oc get storageclass lvms-${LVMS_DEVICE_CLASS_NAME} &>/dev/null; do
        sleep 10
    done
" || { echo "Error: StorageClass lvms-${LVMS_DEVICE_CLASS_NAME} was not created within 300s" >&2; \
       exit 1; }

echo "✔ LVMCluster ready with deviceClass: ${LVMS_DEVICE_CLASS_NAME}"
echo ""
echo "StorageClass created: lvms-${LVMS_DEVICE_CLASS_NAME}"
oc get storageclass lvms-${LVMS_DEVICE_CLASS_NAME}
