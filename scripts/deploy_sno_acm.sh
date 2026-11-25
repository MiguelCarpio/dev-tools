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
# - SNO_RELEASE_IMAGE: OCP release image (e.g. quay.io/.../ocp-release:4.20.46-x86_64)
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

echo "Provisioning SNO cluster: ${NS}.${SNO_BASE_DOMAIN}"
echo "Release image: ${SNO_RELEASE_IMAGE}"
echo "BMC: ${SNO_BMC_HOST} (boot MAC: ${SNO_NODE_MAC})"

# Precheck: ACM hub must be running
echo "Checking that the ACM hub (MultiClusterHub) is running..."
oc wait --for=jsonpath='{.status.phase}'=Running multiclusterhub/multiclusterhub \
    -n open-cluster-management --timeout=10s \
    || { echo "Error: MultiClusterHub is not Running on this cluster (run 'make install_acm_operator' first)" >&2; exit 1; }

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

# 10. Wait for the installation to complete (virtual media boot + discovery + SNO
# install; this typically takes 30-60 minutes)
echo "Waiting for the SNO installation to complete (this takes 30-60 minutes)..."
echo "Progress can be followed with:"
echo "  oc -n ${NS} get agents"
echo "  oc -n ${NS} get clusterdeployment ${NS} -o jsonpath='{.status.conditions}'"
oc wait --for=condition=Completed agentclusterinstall/${NS} -n "${NS}" --timeout=3600s

echo "✔ SNO cluster ${NS} is installed"

# 11. Label the ManagedCluster (ACM created and imported it during install)
if [ -n "${SNO_LABELS}" ]; then
    echo "Labelling ManagedCluster: ${SNO_LABELS}"
    oc label managedcluster "${NS}" ${SNO_LABELS} --overwrite
fi

# 12. Manage the cluster endpoints in the workstation /etc/hosts (idempotent,
# marker-delimited block - same pattern as rhoso-rhoai). On SNO the API and
# ingress records all point at the node IP.
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

echo ""
echo "✔ Done. Cluster status:"
echo "  oc -n ${NS} get clusterdeployment ${NS}"
echo "  oc -n ${NS} get agents"
echo "  oc get managedcluster ${NS}"
echo "  oc get secrets -n ${NS} ${NS}-admin-kubeconfig"
echo "Console and credentials:"
echo "  oc -n ${NS} get secret ${NS}-admin-password -o jsonpath='{.data.username}' | base64 -d; echo"
echo "  oc -n ${NS} get secret ${NS}-admin-password -o jsonpath='{.data.password}' | base64 -d; echo"
