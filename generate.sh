#!/bin/sh

set -euo pipefail

# Colors
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_CLEAR='\033[0m'
MASTER_NODES=("master01" "master02" "node06" "node07")
WORKER_NODES=("node01" "node02" "node03" "node04")
CLUSTER_NAME="pureroot"
CLUSTER_API_ENDPOINT="https://k8s.pureroot.com:6443"

# renovate: datasource=github-releases depName=siderolabs/talos
TALOS_VERSION=v1.10.3
# Use https://factory.talos.dev to generate an installer image ID
CONTROL_PLANE_INSTALLER_ID=$(curl -fSsL -X POST --data-binary @./controlplane/schematic.yaml https://factory.talos.dev/schematics | jq -r .id)
WORKER_INSTALLER_ID=$(curl -fSsL -X POST --data-binary @./workers/schematic.yaml https://factory.talos.dev/schematics | jq -r .id)
export WORKER_IMAGE="factory.talos.dev/installer/${WORKER_INSTALLER_ID}:${TALOS_VERSION}"
export CONTROL_PLANE_IMAGE="factory.talos.dev/installer/${CONTROL_PLANE_INSTALLER_ID}:${TALOS_VERSION}"

# Clear any old generated files
for node in "${MASTER_NODES[@]}"; do
    rm -f $node.yaml
    rm -f $node.yaml.tmp
done

for node in "${WORKER_NODES[@]}"; do
    rm -f $node.yaml
    rm -f $node.yaml.tmp
done

rm -rf controlplane.yaml controlplane-premachine.yaml controlplane-precluster.yaml worker.yaml worker-premachine.yaml worker-precluster.yaml nut.worker.yaml nut.controlplane.yaml tailscale.yaml

# If secrets.yaml doesn't exist, create it
if [ ! -f secrets.yaml ]; then
    echo -e "${COLOR_YELLOW}Note: ${COLOR_CLEAR}${COLOR_GREEN}No secrets.yaml found, using 'talosctl gen secrets' to create it...${COLOR_CLEAR}" >&2
    talosctl gen secrets
    yq -i '.nut.user = "k8s"' secrets.yaml
    yq -i ".nut.pass = \"$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 64; echo)\"" secrets.yaml
    yq -i '.tailscale.auth = "CHANGEME"' secrets.yaml
    echo -e "${COLOR_RED}Warning: Save your secrets.yaml somewhere safe!${COLOR_CLEAR}" >&2
fi

# Use talosctl to generate the node configs
talosctl gen config --with-secrets secrets.yaml --config-patch-control-plane @./controlplane/controlplane.common.yaml --output-types controlplane --force -o controlplane-premachine.yaml ${CLUSTER_NAME} ${CLUSTER_API_ENDPOINT}
talosctl machineconfig patch controlplane-premachine.yaml --patch @machine.common.yaml --output controlplane-precluster.yaml
talosctl machineconfig patch controlplane-precluster.yaml --patch @cluster.common.yaml --output controlplane.yaml
rm controlplane-premachine.yaml controlplane-precluster.yaml

for node in "${MASTER_NODES[@]}"; do
    if [ -e ./controlplane/${node}.patch.yaml ]; then
        talosctl machineconfig patch controlplane.yaml --patch @./controlplane/${node}.patch.yaml --output ${node}.yaml
        yq -i '.machine.install.image = strenv(CONTROL_PLANE_IMAGE)' ${node}.yaml
    fi
    if [ -e ./controlplane/${node}.storage.yaml ]; then
        cat ./controlplane/${node}.storage.yaml >> ${node}.yaml
    fi
done
rm controlplane.yaml

talosctl gen config --with-secrets secrets.yaml --config-patch-worker @./workers/worker.common.yaml --output-types worker --force -o worker-premachine.yaml ${CLUSTER_NAME} ${CLUSTER_API_ENDPOINT}
talosctl machineconfig patch worker-premachine.yaml --patch @machine.common.yaml --output worker-precluster.yaml
talosctl machineconfig patch worker-precluster.yaml --patch @cluster.common.yaml --output worker.yaml
rm worker-premachine.yaml worker-precluster.yaml

for node in "${WORKER_NODES[@]}"; do
    if [ -e ./workers/${node}.patch.yaml ]; then
        talosctl machineconfig patch worker.yaml --patch @./workers/${node}.patch.yaml --output ${node}.yaml
         yq -i '.machine.install.image = strenv(WORKER_IMAGE)' ${node}.yaml
    fi
    if [ -e ./workers/${node}.storage.yaml ]; then
        cat ./workers/${node}.storage.yaml >> ${node}.yaml
    fi
done

rm worker.yaml


# UPS_USER="$(cat secrets.yaml | yq -r .nut.user)" UPS_PASS="$(cat secrets.yaml | yq -r .nut.pass)" UPS_HOST="192.168.1.39" envsubst < nut.yaml.tpl > nut.worker.yaml
# UPS_USER="$(cat secrets.yaml | yq -r .nut.user)" UPS_PASS="$(cat secrets.yaml | yq -r .nut.pass)" UPS_HOST="192.168.1.19" envsubst < nut.yaml.tpl > nut.controlplane.yaml
# TS_AUTHKEY="$(cat secrets.yaml | yq -r .tailscale.auth)" envsubst < tailscale.yaml.tpl > tailscale.yaml

# cat node01.yaml nut.worker.yaml tailscale.yaml > node01.yaml.tmp
# mv node01.yaml.tmp node01.yaml
# cat node02.yaml nut.worker.yaml tailscale.yaml > node02.yaml.tmp
# mv node02.yaml.tmp node02.yaml
# cat node04.yaml nut.worker.yaml tailscale.yaml > node04.yaml.tmp
# mv node04.yaml.tmp node04.yaml
# # Delta is physically on the same UPS as control plane nodes
# cat delta.yaml nut.controlplane.yaml tailscale.yaml > delta.yaml.tmp
# mv delta.yaml.tmp delta.yaml
# cat master01.yaml nut.controlplane.yaml tailscale.yaml > master01.yaml.tmp
# mv master01.yaml.tmp master01.yaml
# cat node06.yaml nut.controlplane.yaml tailscale.yaml > node06.yaml.tmp
# mv node06.yaml.tmp node06.yaml
# cat node07.yaml nut.controlplane.yaml tailscale.yaml > node07.yaml.tmp
# mv node07.yaml.tmp node07.yaml
