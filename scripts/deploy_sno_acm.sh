#!/bin/bash

set -e

# Deploy a single-node OpenShift managed cluster via ACM / central
# infrastructure management (agent-based installer), on the hub where the
# MultiClusterHub is running.
#
# Required environment variables:
# - SNO_CLUSTER_NAME:  cluster name (also the namespace and BMC secret name)
# - SNO_BASE_DOMAIN:   base domain of the cluster FQDN
# - SNO_BMC_HOST:      iDRAC/Redfish address of the node (e.g. https://10.37.137.x)
# - SNO_BMC_USERNAME:  BMC username
# - SNO_BMC_PASSWORD:  BMC password
# - SNO_NODE_MAC:      MAC address of the provisioning interface
# - SNO_RELEASE_IMAGE or OPENSHIFT_VERSION: the exact OCP release image
#   (e.g. quay.io/.../ocp-release:4.20.46-x86_64), or a version number
#   (e.g. 4.20.46) from which the release image is derived
# - Static node networking (on SNO the node IP is also the API/ingress VIP,
#   so the address must be known up front - DHCP is not supported):
#   - SNO_NODE_IP / SNO_NODE_PREFIX / SNO_NODE_GW / SNO_NODE_DNS / SNO_NODE_IFACE
#
# Optional environment variables:
# - SNO_ROOT_DEVICE:   root device hint (default: /dev/sda)
# - SNO_SSH_PUBKEY:    SSH public key to inject into the SNO
# - SNO_LABELS:        labels to apply to the ManagedCluster after import
#                      (e.g. "rhoso-version=19"), for ApplicationSet/Placement targeting
#
# Based on the Red Hat documented procedure (ACM / multicluster engine,
# creating an on-premises cluster with the agent-based installer): namespace
# + BMC secret + pull secret + NMStateConfig + InfraEnv + AgentClusterInstall
# + ClusterDeployment + BareMetalHost. The node is booted over Redfish with
# the discovery ISO generated from the InfraEnv; the Agent it registers is
# bound to the ClusterDeployment and installs SNO. ACM creates and imports
# the ManagedCluster automatically.
#
# https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.14/html/clusters/

NS="${SNO_CLUSTER_NAME}"
ROOT_DEVICE="${SNO_ROOT_DEVICE:-/dev/sda}"

# SNO_RELEASE_IMAGE takes precedence; derive it from OPENSHIFT_VERSION otherwise
if [ -z "${SNO_RELEASE_IMAGE}" ] && [ -n "${OPENSHIFT_VERSION}" ]; then
    SNO_RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:${OPENSHIFT_VERSION}-x86_64"
fi

echo "Provisioning SNO cluster: ${NS}.${SNO_BASE_DOMAIN}"
echo "Release image: ${SNO_RELEASE_IMAGE}"
echo "BMC: ${SNO_BMC_HOST} (boot MAC: ${SNO_NODE_MAC})"

# Precheck: ACM hub must be running
echo "Checking that the ACM hub (MultiClusterHub) is running..."
oc wait --for=jsonpath='{.status.phase}'=Running multiclusterhub/multiclusterhub \
    -n open-cluster-management --timeout=10s \
    || { echo "Error: MultiClusterHub is not Running on this cluster (run 'make install_acm_operator' first)" >&2; exit 1; }

# Precheck: the target OCP version must be in the assisted-service OS image
# list. The defaults only cover the hub's version window; installing another
# minor (e.g. 4.18 on a 4.20 hub) requires adding an osImages entry to the
# AgentServiceConfig (documented in the InfraEnv field descriptions).
# The effective list (defaults + AgentServiceConfig entries) is published in
# the assisted-service configmap.
TARGET_MINOR=$(echo "${SNO_RELEASE_IMAGE}" | sed -n 's/.*:\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
if [ -z "${TARGET_MINOR}" ]; then
    echo "Error: could not extract the major.minor version from SNO_RELEASE_IMAGE (${SNO_RELEASE_IMAGE})" >&2
    exit 1
fi

OS_IMAGES=$(oc get configmap assisted-service -n multicluster-engine -o jsonpath='{.data.OS_IMAGES}')
if echo "${OS_IMAGES}" | grep -q "\"openshift_version\":\"${TARGET_MINOR}\""; then
    echo "OCP ${TARGET_MINOR} is in the assisted OS image list"
else
    echo "OCP ${TARGET_MINOR} is not in the assisted OS image list; adding it"

    # RHCOS build of the target release, from the release payload
    PULL_SECRET_FILE=$(mktemp)
    oc -n "${NS}" get secret assisted-pull-secret -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null | base64 -d > "${PULL_SECRET_FILE}"
    if [ ! -s "${PULL_SECRET_FILE}" ]; then
        # the assisted-pull-secret is created later in this script on first
        # run; fall back to the hub's global pull secret
        oc extract secret/pull-secret -n openshift-config --confirm --to="${TMPDIR:-/tmp}" >/dev/null
        mv "${TMPDIR:-/tmp}/.dockerconfigjson" "${PULL_SECRET_FILE}"
    fi
    RHCOS_VERSION=$(oc adm release info "${SNO_RELEASE_IMAGE}" --registry-config "${PULL_SECRET_FILE}" 2>/dev/null \
        | awk '/machine-os/ {print $2}')
    rm -f "${PULL_SECRET_FILE}"
    if [ -z "${RHCOS_VERSION}" ]; then
        echo "Error: could not determine the RHCOS version of ${SNO_RELEASE_IMAGE}" >&2
        exit 1
    fi
    echo "RHCOS version for ${TARGET_MINOR}: ${RHCOS_VERSION}"

    # Live ISO and rootfs URLs from the public mirror. The per-release
    # directory naming differs across streams (4.18.x vs 416.94.x), so
    # resolve the filenames through the <minor>/latest/ directory listing
    MIRROR_LATEST="https://mirror.openshift.com/pub/openshift-v4/x86_64/dependencies/rhcos/${TARGET_MINOR}/latest"
    RHCOS_ISO=$(curl -s "${MIRROR_LATEST}/" | grep -oE 'rhcos-[^"]*live\.x86_64\.iso' | head -1)
    RHCOS_ROOTFS=$(curl -s "${MIRROR_LATEST}/" | grep -oE 'rhcos-[^"]*live-rootfs\.x86_64\.img' | head -1)
    if [ -z "${RHCOS_ISO}" ] || [ -z "${RHCOS_ROOTFS}" ]; then
        echo "Error: could not resolve the RHCOS images for ${TARGET_MINOR} at ${MIRROR_LATEST}" >&2
        exit 1
    fi
    RHCOS_ISO_URL="${MIRROR_LATEST}/${RHCOS_ISO}"
    RHCOS_ROOTFS_URL="${MIRROR_LATEST}/${RHCOS_ROOTFS}"

    # Add the entry to the AgentServiceConfig, merging with any existing
    # osImages entries (the patch replaces the list)
    python3 - "${TARGET_MINOR}" "${RHCOS_VERSION}" "${RHCOS_ISO_URL}" "${RHCOS_ROOTFS_URL}" <<'PYEOF' > /tmp/osimages-patch.json
import json, subprocess, sys
minor, version, url, rootfs = sys.argv[1:5]
asc = json.loads(subprocess.check_output(
    ["oc", "get", "agentserviceconfig", "agent", "-o", "json"]))
os_images = asc.get("spec", {}).get("osImages") or []
if not any(e.get("openshiftVersion") == minor for e in os_images):
    os_images.append({
        "openshiftVersion": minor,
        "cpuArchitecture": "x86_64",
        "version": version,
        "url": url,
        "rootFSUrl": rootfs,
    })
print(json.dumps({"spec": {"osImages": os_images}}))
PYEOF
    oc patch agentserviceconfig agent --type merge --patch-file /tmp/osimages-patch.json
    rm -f /tmp/osimages-patch.json

    # Wait for the assisted-service to pick up the new image before the
    # AgentClusterInstall is synced (otherwise SpecSynced fails with
    # "No OS images are available for version ...")
    echo "Waiting for OCP ${TARGET_MINOR} to appear in the assisted OS image list..."
    timeout 300s bash -c "
        until oc get configmap assisted-service -n multicluster-engine -o jsonpath='{.data.OS_IMAGES}' 2>/dev/null | grep -q '\"openshift_version\":\"${TARGET_MINOR}\"'; do
            sleep 10
        done
    " || { echo "Error: OCP ${TARGET_MINOR} did not appear in the assisted OS image list within 300s" >&2; exit 1; }
fi

# 1. Namespace (BMH, InfraEnv, AgentClusterInstall and ClusterDeployment must share it)
echo "Creating namespace ${NS}..."
cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
EOF

# 2. BMC credentials secret
echo "Creating BMC credentials secret..."
cat << EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${NS}-bmc
  namespace: ${NS}
type: Opaque
stringData:
  username: "${SNO_BMC_USERNAME}"
  password: "${SNO_BMC_PASSWORD}"
EOF

# 3. Pull secret (copy of the hub's global pull secret)
echo "Creating assisted pull secret (copied from the hub's global pull secret)..."
oc extract secret/pull-secret -n openshift-config --confirm --to="${TMPDIR:-/tmp}" >/dev/null
oc create secret generic assisted-pull-secret -n "${NS}" \
    --from-file=.dockerconfigjson="${TMPDIR:-/tmp}/.dockerconfigjson" --dry-run=client -o yaml | oc apply -f -
rm -f "${TMPDIR:-/tmp}/.dockerconfigjson"

# 4. NMStateConfig (static networking, matched to the boot MAC).
# On SNO the node IP serves as the API and ingress VIP, so the node address
# must be known up front (static, not DHCP).
echo "Creating NMStateConfig (static: ${SNO_NODE_IP}/${SNO_NODE_PREFIX} on ${SNO_NODE_IFACE})..."
cat << EOF | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: NMStateConfig
metadata:
  name: ${NS}
  namespace: ${NS}
  labels:
    infraenvs.agent-install.openshift.io: ${NS}
spec:
  config:
    interfaces:
    - name: ${SNO_NODE_IFACE}
      type: ethernet
      state: up
      mac-address: "${SNO_NODE_MAC}"
      ipv4:
        enabled: true
        address:
        - ip: ${SNO_NODE_IP}
          prefix-length: ${SNO_NODE_PREFIX}
        dhcp: false
    dns-resolver:
      config:
        server:
        - ${SNO_NODE_DNS}
    routes:
      config:
      - destination: 0.0.0.0/0
        next-hop-address: ${SNO_NODE_GW}
        next-hop-interface: ${SNO_NODE_IFACE}
EOF

# 5. InfraEnv (discovery ISO)
echo "Creating InfraEnv..."
cat << EOF | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ${NS}
  namespace: ${NS}
spec:
  clusterRef:
    name: ${NS}
    namespace: ${NS}
  pullSecretRef:
    name: assisted-pull-secret
EOF
# tag InfraEnv so it owns the NMStateConfig label above
oc -n "${NS}" label infraenv/${NS} infraenvs.agent-install.openshift.io=${NS} --overwrite >/dev/null

# 6. AgentClusterInstall (SNO: 1 control plane agent, 0 workers)
echo "Creating AgentClusterInstall (SNO)..."
cat << EOF | oc apply -f -
apiVersion: extensions.hive.openshift.io/v1beta1
kind: AgentClusterInstall
metadata:
  name: ${NS}
  namespace: ${NS}
spec:
  clusterDeploymentRef:
    name: ${NS}
  imageSetRef:
    name: ${NS}
  networking:
    networkType: OVNKubernetes
    clusterNetworks:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
    serviceNetworks:
    - cidr: 172.30.0.0/16
    apiVIPs:
    - ${SNO_NODE_IP}
    ingressVIPs:
    - ${SNO_NODE_IP}
  provisionRequirements:
    controlPlaneAgents: 1
    workersAgents: 0
  sshPublicKey: "${SNO_SSH_PUBKEY}"
EOF

# 7. ClusterImageSet (pinned OCP release) + ClusterDeployment
echo "Creating ClusterImageSet and ClusterDeployment..."
cat << EOF | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: ${NS}
spec:
  releaseImage: ${SNO_RELEASE_IMAGE}
---
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: ${NS}
  namespace: ${NS}
spec:
  clusterName: ${NS}
  baseDomain: ${SNO_BASE_DOMAIN}
  platform:
    agentBareMetal:
      agentSelector:
        matchLabels:
          agent-install.openshift.io/bmc-role: master
  clusterInstallRef:
    name: ${NS}
    group: extensions.hive.openshift.io
    version: v1beta1
    kind: AgentClusterInstall
  # no spec.provisioning: it is mutually exclusive with clusterInstallRef
  # (the provisioning configuration lives in the AgentClusterInstall)
  pullSecretRef:
    name: assisted-pull-secret
EOF

# 8. Metal3 Provisioning configuration (same as the rhoso-gitops-brq2 lab:
# no dedicated provisioning network, virtual media via the external network,
# BMHs watched in all namespaces)
echo "Configuring metal3 Provisioning..."
cat << EOF | oc apply -f -
apiVersion: metal3.io/v1alpha1
kind: Provisioning
metadata:
  name: provisioning-configuration
  namespace: ${NS}
spec:
  provisioningNetwork: Disabled
  virtualMediaViaExternalNetwork: true
  watchAllNamespaces: true
EOF

# 9. BareMetalHost (boots the discovery ISO over the BMC virtual media)
echo "Creating BareMetalHost..."
cat << EOF | oc apply -f -
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ${NS}
  namespace: ${NS}
  annotations:
    bmac.agent-install.openshift.io/role: master
  labels:
    infraenvs.agent-install.openshift.io: ${NS}
spec:
  online: true
  bootMACAddress: "${SNO_NODE_MAC}"
  bmc:
    address: "${SNO_BMC_HOST}"
    credentialsName: ${NS}-bmc
    disableCertificateVerification: true
  rootDeviceHints:
    deviceName: ${ROOT_DEVICE}
EOF

# 10. Manage the cluster endpoints in the workstation /etc/hosts (idempotent,
# marker-delimited block - same pattern as rhoso-rhoai). On SNO the API and
# ingress records all point at the node IP. Done before the wait so the
# entries exist as soon as the install completes, even if the wait times out.
FQDN="${NS}.${SNO_BASE_DOMAIN}"
hosts="# Generated by dev-tools for SNO ${NS} - Do not edit
${SNO_NODE_IP} api.${FQDN}
${SNO_NODE_IP} api-int.${FQDN}
${SNO_NODE_IP} console-openshift-console.apps.${FQDN}
${SNO_NODE_IP} oauth-openshift.apps.${FQDN}
${SNO_NODE_IP} downloads-openshift-console.apps.${FQDN}
${SNO_NODE_IP} canary-openshift-ingress-canary.apps.${FQDN}
# End of dev-tools ${NS} endpoints"

old_hosts=$(awk "/# Generated by dev-tools for SNO ${NS} - Do not edit/,/# End of dev-tools ${NS} endpoints/" /etc/hosts)

if [ "${hosts}" != "${old_hosts}" ]; then
    echo "Updating /etc/hosts with the ${NS} endpoints"
    sudo sed -i "/# Generated by dev-tools for SNO ${NS} - Do not edit/,/# End of dev-tools ${NS} endpoints/d" /etc/hosts
    echo "${hosts}" | sudo tee -a /etc/hosts >/dev/null
fi

# 11. Make the cluster API endpoint resolvable from the hub (idempotent), so
# hub components (Hive import, ACM) can reach it. Deploy a CoreDNS backend
# in the cluster namespace and forward the cluster zone to it from the DNS
# CR. The backend runs on the
# unprivileged port 5353 (the restricted SCC cannot bind 53) and the Service
# translates 53 -> 5353, so the DNS CR upstream uses the default port.
if ! oc -n "${NS}" get deploy coredns-backend &>/dev/null; then
    echo "Deploying CoreDNS backend for zone ${FQDN}"
    COREDNS_IMAGE=$(oc -n openshift-dns get ds dns-default -o jsonpath='{.spec.template.spec.containers[0].image}')
    cat << EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-backend
  namespace: ${NS}
data:
  Corefile: |
    ${FQDN}:5353 {
        hosts {
            ${SNO_NODE_IP} api.${FQDN}
            ${SNO_NODE_IP} api-int.${FQDN}
            ${SNO_NODE_IP} console-openshift-console.apps.${FQDN}
            ${SNO_NODE_IP} oauth-openshift.apps.${FQDN}
        }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: coredns-backend
  namespace: ${NS}
spec:
  replicas: 1
  selector:
    matchLabels: {app: coredns-backend}
  template:
    metadata:
      labels: {app: coredns-backend}
    spec:
      containers:
      - name: coredns
        image: ${COREDNS_IMAGE}
        args: ["-conf", "/etc/coredns/Corefile"]
        ports:
        - containerPort: 5353
          protocol: UDP
        - containerPort: 5353
          protocol: TCP
        volumeMounts:
        - {name: conf, mountPath: /etc/coredns}
      volumes:
      - name: conf
        configMap: {name: coredns-backend}
---
apiVersion: v1
kind: Service
metadata:
  name: coredns-backend
  namespace: ${NS}
spec:
  selector: {app: coredns-backend}
  ports:
  - {name: dns-udp, port: 53, targetPort: 5353, protocol: UDP}
  - {name: dns-tcp, port: 53, targetPort: 5353, protocol: TCP}
EOF
    oc -n "${NS}" rollout status deploy/coredns-backend --timeout=120s
fi

# Forward the cluster zone to the CoreDNS backend from the DNS CR (the
# supported, operator-managed route: the operator renders the zone into the
# Corefile itself and defends it)
BACKEND_IP=$(oc -n "${NS}" get svc coredns-backend -o jsonpath='{.spec.clusterIP}')
if ! oc get dns.operator.openshift.io default -o jsonpath='{.spec.servers}' | grep -q "\"${FQDN}\""; then
    echo "Forwarding zone ${FQDN} to the CoreDNS backend (${BACKEND_IP})"
    oc patch dns.operator.openshift.io default --type merge \
        -p "{\"spec\":{\"servers\":[{\"name\":\"${NS}\",\"zones\":[\"${FQDN}\"],\"forwardPlugin\":{\"upstreams\":[\"${BACKEND_IP}\"]}}]}}"
    oc -n openshift-dns rollout restart daemonset/dns-default
fi

# 12. Wait for the installation to complete (virtual media boot + discovery + SNO
# install; this typically takes 30-60 minutes)
echo "Waiting for the SNO installation to complete (this takes 30-60 minutes)..."
echo "Progress can be followed with:"
echo "  oc -n ${NS} get bmh ${NS} -w"
echo "  oc -n ${NS} get infraenv ${NS} -o jsonpath='{.status.conditions}'"
echo "  oc -n ${NS} get agents"
echo "  oc -n ${NS} get agentclusterinstall ${NS} -o jsonpath='{.status.conditions}'"
oc wait --for=condition=Completed agentclusterinstall/${NS} -n "${NS}" --timeout=3600s

echo "✔ SNO cluster ${NS} is installed"

# 13. Create the ManagedCluster. CLI-created Hive clusters are NOT
# auto-imported by ACM (only console-created ones are): the ManagedCluster
# must be created explicitly, after which the hub uses the admin kubeconfig
# Hive stored to install the klusterlet and import the cluster.
if ! oc get managedcluster "${NS}" &>/dev/null; then
    echo "Creating ManagedCluster ${NS}"
    cat << EOF | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: ${NS}
  labels:
    cloud: auto-detect
    vendor: auto-detect
spec:
  hubAcceptsClient: true
EOF
fi

oc wait --for=condition=Joined managedcluster/${NS} --timeout=600s

# 14. Label the ManagedCluster (for ApplicationSet/Placement targeting)
if [ -n "${SNO_LABELS}" ]; then
    echo "Labelling ManagedCluster: ${SNO_LABELS}"
    oc label managedcluster "${NS}" ${SNO_LABELS} --overwrite
fi

echo ""
echo "✔ Done. Cluster status:"
echo "  oc -n ${NS} get clusterdeployment ${NS}"
echo "  oc -n ${NS} get agents"
echo "  oc get managedcluster ${NS}"
echo "  oc get secrets -n ${NS} ${NS}-admin-kubeconfig"
echo "Console and credentials:"
echo "  oc -n ${NS} get secret ${NS}-admin-password -o jsonpath='{.data.username}' | base64 -d; echo"
echo "  oc -n ${NS} get secret ${NS}-admin-password -o jsonpath='{.data.password}' | base64 -d; echo"
