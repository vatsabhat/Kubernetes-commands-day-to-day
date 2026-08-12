#!/bin/bash
# ==============================================================================
#                      KUBERNETES HA DEPLOYMENT SCRIPT
# ==============================================================================
# Instructions:
# 1. Copy this entire script into Notepad and save it as 'deploy-k8s.sh'.
# 2. Upload it to BOTH Ubuntu servers.
# 3. Update the CONFIGURATION block below on both nodes.
# 4. Run on Node 1 (set CURRENT_NODE="1"), then copy the join token.
# 5. Run on Node 2 (set CURRENT_NODE="2"), then paste the join token.
# ==============================================================================

set -e

# ==========================================
# CONFIGURATION - UPDATE THESE VARIABLES
# ==========================================
VIP="192.168.1.50"                 # Your desired Virtual IP
INTERFACE="eth0"                   # Network interface name (check 'ip a')
NODE_1_IP="192.168.1.11"           # IP of Control Plane 1
NODE_2_IP="192.168.1.12"           # IP of Control Plane 2
CURRENT_NODE="1"                   # Set to "1" on Node 1, and "2" on Node 2
K8S_VERSION="1.30"                 # Target Kubernetes version
POD_CIDR="10.244.0.0/16"           # Pod network subnet
# ==========================================

echo "=== 1. Preparing System Prerequisites ==="
sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gnupg software-properties-common

# Disable Swap (Required by Kubernetes)
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Load Kernel Modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Set Sysctl Parameters
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

echo "=== 2. Installing Containerd Runtime ==="
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd

echo "=== 3. Installing HAProxy and Keepalived for VIP ==="
sudo apt-get install -y keepalived haproxy

# Configure Keepalived
PRIORITY=$((100 - CURRENT_NODE))
cat <<EOF | sudo tee /etc/keepalived/keepalived.conf
vrrp_script check_haproxy {
    script "killall -0 haproxy"
    interval 2
    weight 2
}
vrrp_instance VI_1 {
    state $( [ "$CURRENT_NODE" == "1" ] && echo "MASTER" || echo "BACKUP" )
    interface $INTERFACE
    virtual_router_id 51
    priority $PRIORITY
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass K8sVIPSecret
    }
    virtual_ipaddress {
        $VIP
    }
    track_script {
        check_haproxy
    }
}
EOF

# Configure HAProxy
cat <<EOF | sudo tee /etc/haproxy/haproxy.cfg
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    user haproxy
    group haproxy
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    retries 3
    timeout queue           1m
    timeout connect         10s
    timeout client          1m
    timeout server          1m

frontend k8s-api
    bind $VIP:6443
    mode tcp
    option tcplog
    default_backend k8s-api-backend

backend k8s-api-backend
    mode tcp
    option tcplog
    option httpchk GET /healthz
    balance roundrobin
    server control1 $NODE_1_IP:6443 check check-ssl verify none
    server control2 $NODE_2_IP:6443 check check-ssl verify none
EOF

sudo systemctl restart keepalived haproxy
sudo systemctl enable keepalived haproxy

echo "=== 4. Installing Kubernetes Tools (kubeadm, kubelet, kubectl) ==="
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://k8s.io{K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://k8s.io{K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

echo "=== 5. Initializing Cluster Component Deployment ==="
# Install Helm for supplementary stack deployments
curl https://githubusercontent.com | bash

if [ "$CURRENT_NODE" == "1" ]; then
    echo "Initializing cluster on first control plane..."
    cat <<EOF | sudo tee kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}.0
controlPlaneEndpoint: "${VIP}:6443"
networking:
  podSubnet: "${POD_CIDR}"
EOF
    
    sudo kubeadm init --config=kubeadm-config.yaml --upload-certs
    
    # Configure kubectl for root user
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config

    echo "=== 6. Deploying Infrastructure Stack (Networking, DNS, Storage, Monitoring) ==="
    
    # Allow scheduling on control planes (since this is a 2-node control plane only setup)
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

    # Cilium CNI (Networking & CoreDNS setup auto-resolves here)
    helm repo add cilium https://cilium.io
    helm repo update
    helm install cilium cilium/cilium --version 1.15.5 --namespace kube-system --set operator.replicas=1

    # Local Path Storage Provisioner
    kubectl apply -f https://githubusercontent.com
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

    # Prometheus & Grafana Monitoring Stack
    helm repo add prometheus-community https://github.io
    helm repo update
    helm install prometheus prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace \
      --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
      --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
      --set grafana.storage.enabled=true \
      --set grafana.storage.type=pvc \
      --set grafana.storage.size=10Gi

    echo "=========================================================="
    echo "SUCCESS: Node 1 setup complete!"
    echo "1. Look at the terminal output above."
    echo "2. Copy the command starting with 'kubeadm join ...'"
    echo "3. Ensure it contains '--control-plane' and '--certificate-key'"
    echo "4. Paste that exact command onto Node 2 after its script finishes."
    echo "=========================================================="
else
    echo "=========================================================="
    echo "SUCCESS: Node 2 system prerequisites and VIP engine loaded!"
    echo "Please paste your 'kubeadm join' token string generated by Node 1"
    echo "into this terminal right now to join the cluster."
    echo "=========================================================="
fi
