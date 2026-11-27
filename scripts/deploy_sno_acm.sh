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
# - SNO_RELEASE_IMAGE: OCP release image (e.g. quay.io/.../ocp-release:4.20.46-x86_64);
#   the Makefile derives it from OPENSHIFT_VERSION when unset
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
ROOT_DEVICE="${SNO_ROOT_DEVICE}"
INSTALL_TIMEOUT="${SNO_INSTALL_TIMEOUT}"

echo "Provisioning SNO cluster: ${NS}.${SNO_BASE_DOMAIN}"
echo "Release image: ${SNO_RELEASE_IMAGE}"
echo "BMC: ${SNO_BMC_HOST} (boot MAC: ${SNO_NODE_MAC})"

# Precheck: ACM hub must be running
echo "Checking that the ACM hub (MultiClusterHub) is running..."
oc wait --for=jsonpath='{.status.phase}'=Running multiclusterhub/multiclusterhub \
    -n open-cluster-management --timeout=10s \
    || { echo "Error: MultiClusterHub is not Running on this cluster (run 'make install_acm_operator' first)" >&2; exit 1; }

# Precheck: the target OCP version must be in the assisted-service OS image
# list, which is the set of versions the hub supports installing (the list
# is published in the assisted-service configmap). Installing a version
# outside this list requires workarounds that are not supported:
#
# - Pre-4.19 targets: MCE 2.17 release notes, known issue 1.3.30
#   (ACM-14943) - "single-node OpenShift cluster installation requires
#   matching OpenShift Container Platform with infrastructure operator for
#   Red Hat OpenShift" - the InfraEnv and the booted host must use the
#   same OCP version as the cluster being installed; the installation
#   fails if the versions do not match (observed as a segfault loop in
#   openshift-install create manifests on the hub's assisted-service).
#
# Use a version from the supported list, or the deploy_sno flow
# (bm_sno/ci-framework), which downloads a version-matched
# openshift-install and is not bound by the hub's window.
TARGET_MINOR=$(echo "${SNO_RELEASE_IMAGE}" | sed -n 's/.*:\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
if [ -z "${TARGET_MINOR}" ]; then
    echo "Error: could not extract the major.minor version from SNO_RELEASE_IMAGE (${SNO_RELEASE_IMAGE})" >&2
    exit 1
fi

OS_IMAGES=$(oc get configmap assisted-service -n multicluster-engine -o jsonpath='{.data.OS_IMAGES}')
if echo "${OS_IMAGES}" | grep -q "\"openshift_version\":\"${TARGET_MINOR}\""; then
    echo "OCP ${TARGET_MINOR} is supported by the hub's assisted service"
else
    SUPPORTED_MINORS=$(echo "${OS_IMAGES}" | grep -o '"openshift_version":"[^"]*"' | cut -d'"' -f4 | sort -u | tr '\n' ' ')
    echo "Error: OCP ${TARGET_MINOR} is not in the hub's assisted OS image list (supported: ${SUPPORTED_MINORS})" >&2
    echo "Use a supported version, or the deploy_sno flow (bm_sno) for versions outside the hub's window" >&2
    exit 1
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
# Corefile itself and defends it). The patch must MERGE with the existing
# servers entries: a merge patch replaces arrays, so patching with only
# this cluster's entry would drop the zone forwards of every other
# cluster on the hub.
BACKEND_IP=$(oc -n "${NS}" get svc coredns-backend -o jsonpath='{.spec.clusterIP}')
if ! oc get dns.operator.openshift.io default -o jsonpath='{.spec.servers}' | grep -q "\"${FQDN}\""; then
    echo "Forwarding zone ${FQDN} to the CoreDNS backend (${BACKEND_IP})"
    python3 - "${NS}" "${FQDN}" "${BACKEND_IP}" <<'PYEOF' > /tmp/dnscr-patch.json
import json, subprocess, sys
ns, fqdn, ip = sys.argv[1:4]
dns = json.loads(subprocess.check_output(
    ["oc", "get", "dns.operator.openshift.io", "default", "-o", "json"]))
servers = dns.get("spec", {}).get("servers") or []
if not any(fqdn in z for s in servers for z in s.get("zones", [])):
    servers.append({
        "name": ns,
        "zones": [fqdn],
        "forwardPlugin": {"upstreams": [ip]},
    })
print(json.dumps({"spec": {"servers": servers}}))
PYEOF
    oc patch dns.operator.openshift.io default --type merge --patch-file /tmp/dnscr-patch.json
    rm -f /tmp/dnscr-patch.json
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
oc wait --for=condition=Completed agentclusterinstall/${NS} -n "${NS}" --timeout=${INSTALL_TIMEOUT}

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
