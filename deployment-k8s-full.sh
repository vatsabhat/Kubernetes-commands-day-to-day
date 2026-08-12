#!/bin/bash
# ==============================================================================
#                 KUBERNETES HA ALL-IN-ONE AUTOMATION SCRIPT
# ==============================================================================
# Instructions:
# 1. Paste this entire script into Notepad on your machine.
# 2. Save the file as 'deploy-all.sh' and upload it to BOTH servers.
# 3. Update the CONFIGURATION block variables below to match your home lab network.
# 4. Execute on Node 1 (set CURRENT_NODE="1"), then copy the outputted join token.
# 5. Execute on Node 2 (set CURRENT_NODE="2"), then paste the join token string.
# ==============================================================================

set -e

# ==========================================
# CONFIGURATION - UPDATE THESE VARIABLES
# ==========================================
VIP="192.168.1.50"                 # Target Virtual IP shared by control planes
INTERFACE="eth0"                   # Network interface name (run 'ip a' to check)
NODE_1_IP="192.168.1.11"           # Physical IP of Control Plane 1
NODE_2_IP="192.168.1.12"           # Physical IP of Control Plane 2
CURRENT_NODE="1"                   # Change to "1" on Node 1, and "2" on Node 2
K8S_VERSION="1.30"                 # Stable Kubernetes environment target
POD_CIDR="10.244.0.0/16"           # Private internal pod network subnet
# ==========================================

echo "=== 1. Opening Security & System Firewalls ==="
sudo apt-get update && sudo apt-get install -y ufw
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow proto vrrp
sudo ufw allow 6443/tcp
sudo ufw allow 2379:2380/tcp
sudo ufw allow 10250:10252/tcp
sudo ufw allow 30000:32767/tcp
sudo ufw --force enable

echo "=== 2. Resolving System Prerequisites & Swap Configuration ==="
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg software-properties-common
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Load Essential Networking Kernel Modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Set Core Networking Kernel Hooks
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

echo "=== 3. Deploying Containerd Infrastructure ==="
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd

echo "=== 4. Activating Keepalived and HAProxy Virtual Engines ==="
sudo apt-get install -y keepalived haproxy

# Build local Layer-4 health checking clusters
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

echo "=== 5. Injecting Engine Binaries (kubeadm, kubelet, kubectl) ==="
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://k8s.io{K8S_VERSION}/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://k8s.io{K8S_VERSION}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

echo "=== 6. Fetching Helm Orchestrator package ==="
curl https://githubusercontent.com | bash

if [ "$CURRENT_NODE" == "1" ]; then
    echo "=== 7. Provisioning Master Headend Control Plane (Node 1) ==="
    cat <<EOF | sudo tee kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}.0
controlPlaneEndpoint: "${VIP}:6443"
networking:
  podSubnet: "${POD_CIDR}"
EOF
    
    sudo kubeadm init --config=kubeadm-config.yaml --upload-certs
    
    # Configure root profile environments
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config

    echo "=== 8. Removing Control Plane Workload Taints ==="
    kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

    echo "=== 9. Deploying Cilium Network Architecture Engine ==="
    helm repo add cilium https://cilium.io
    helm repo update
    helm install cilium cilium/cilium --version 1.15.5 --namespace kube-system --set operator.replicas=1

    echo "=== 10. Provisioning Storage Classes ==="
    kubectl apply -f https://githubusercontent.com
    kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

    echo "=== 11. Provisioning Prometheus & Grafana Monitoring Systems ==="
    helm repo add prometheus-community https://github.io
    helm repo update
    helm install prometheus prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace \
      --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
      --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
      --set grafana.storage.enabled=true \
      --set grafana.storage.type=pvc \
      --set grafana.storage.size=10Gi

    echo "=== 12. Adjusting Grafana Access Engine to NodePort Mode ==="
    kubectl patch svc prometheus-grafana -n monitoring -p '{"spec": {"type": "NodePort", "ports": [{"port": 80, "targetPort": 3000, "nodePort": 32000}]}}'

    echo "=== 13. Deploying NGINX Ingress Routing Controller Stack ==="
    helm repo add ingress-nginx https://github.io
    helm repo update
    helm install ingress-nginx ingress-nginx/ingress-nginx \
      --namespace ingress-nginx --create-namespace \
      --set controller.service.type=NodePort \
      --set controller.service.nodePorts.http=80 \
      --set controller.service.nodePorts.https=443

    echo "=== 14. Mounting Ingress Network Mapping Rules ==="
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana-ingress
  namespace: monitoring
  annotations:
    ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  rules:
  - host: grafana.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: prometheus-grafana
            port:
              number: 80
EOF

    echo "========================================================================="
    echo "SUCCESS: Node 1 deployment routine completely finished!"
    echo "========================================================================="
    echo "1. Locate the 'kubeadm join' token block shown above in this window."
    echo "2. Ensure the copied code contains '--control-plane --certificate-key'."
    echo "3. Complete script setup execution on Node 2."
    echo "4. Paste that exact terminal command into Node 2 to complete the cluster."
    echo "========================================================================="
    echo "DASHBOARD ACCESS PORTAL:"
    echo "NodePort URL: http://$VIP:32000"
    echo "Ingress URL:  http://grafana.local (Map '$VIP grafana.local' in hosts file)"
    echo "Username:     admin"
    echo -n "Password:     " && kubectl get secret --namespace monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo
    echo "========================================================================="
else
    echo "========================================================================="
    echo "SUCCESS: Node 2 system prerequisites and VIP engines configured!"
    echo "========================================================================="
    echo "Please paste your secure tokenized 'kubeadm join' command string string"
    echo "generated by the Node 1 runtime terminal output to bind this machine now."
    echo "========================================================================="
fi
