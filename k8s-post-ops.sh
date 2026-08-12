#!/bin/bash
# ==============================================================================
#           KUBERNETES POST-DEPLOYMENT MANAGEMENT & EXTENSION SCRIPT
# ==============================================================================
# Instructions:
# 1. Paste this entire script into Notepad on your machine.
# 2. Save the file as 'k8s-post-ops.sh' and upload it to Node 1.
# 3. Update the CONFIGURATION block variables below to match your environment.
# 4. Make it executable: chmod +x k8s-post-ops.sh
# 5. Run the specific function you need using the flags outlined at the bottom.
# on Node 1. It is broken down into structured execution steps that you can trigger together or sequentially based on your data center requirements.
# ==============================================================================

set -e

# ==========================================
# CONFIGURATION - UPDATE THESE VARIABLES
# ==========================================
# Private DNS Configs
DOMAIN_NAME="mycluster.local"       # Your target private domain name
PRIVATE_DNS_IP="192.168.1.100"      # Your internal network CoreDNS forwarder IP
VIP="192.168.1.50"                  # Shared cluster virtual IP address

# Velero Backup Configs (S3-Compatible Storage / MinIO Setup)
S3_URL="http://192.168.1.60:9000"   # Endpoint for MinIO / S3 backup target
S3_BUCKET="k8s-velero-backups"      # Target bucket name (create before running)
S3_REGION="us-east-1"               # Region string identifier
# ==========================================


# ------------------------------------------------------------------------------
# TASK 1: GENERATE WORKER NODE JOIN TOKENS WITH CUSTOM LABELS / TAINTS
# ------------------------------------------------------------------------------
generate_worker_join() {
    echo "=== [TASK 1] Generating Specialized Worker Node Instructions ==="
    
    # Generate a fresh 24-hour join token from kubeadm
    JOIN_CMD=$(kubeadm token create --print-join-command)
    
    echo "------------------------------------------------------------------------"
    echo "TO JOIN STANDARD WORKER NODES (App Stacks):"
    echo "Run this exact command on your new clean worker node:"
    echo "sudo $JOIN_CMD"
    echo "------------------------------------------------------------------------"
    echo ""
    echo "TO JOIN SPECIALIZED DATABASE WORKER NODES:"
    echo "1. Run the join command above on the target DB node."
    echo "2. Once joined, return to Node 1 and run these labelling/tainting commands:"
    echo "   (Replace 'worker-node-name' with your actual new node's name)"
    echo ""
    echo "   kubectl label nodes worker-node-name node-role.kubernetes.io/database=true"
    echo "   kubectl taint nodes worker-node-name database=true:NoSchedule"
    echo "------------------------------------------------------------------------"
}


# ------------------------------------------------------------------------------
# TASK 2: INSTALL & CONFIGURING PRODUCTION VELERO BACKUPS
# ------------------------------------------------------------------------------
setup_velero_backups() {
    echo "=== [TASK 2] Initializing Velero Production Backup Infrastructure ==="
    
    # Download and extract Velero Client CLI Binary
    VELERO_VER="v1.14.0"
    curl -L https://github.com{VELERO_VER}/velero-${VELERO_VER}-linux-amd64.tar.gz | tar -xz
    sudo mv velero-${VELERO_VER}-linux-amd64/velero /usr/local/bin/
    rm -rf velero-${VELERO_VER}-linux-amd64

    # Ask user for S3 Secret Keys to build credentials file securely
    echo "Please enter your S3 / MinIO access credentials:"
    read -p "Access Key ID: " S3_ACCESS_KEY
    read -sp "Secret Access Key: " S3_SECRET_KEY
    echo ""

    # Generate localized temporary configuration file
    cat <<EOF > credentials-velero
aws_access_key_id=$S3_ACCESS_KEY
aws_secret_access_key=$S3_SECRET_KEY
EOF

    # Install Velero server agent with CSI/snapshot framework parameters
    velero install \
        --provider aws \
        --plugins velero/velero-plugin-for-aws:v1.10.0 \
        --bucket "$S3_BUCKET" \
        --secret-file ./credentials-velero \
        --use-node-agent \
        --uploader-type restic \
        --backup-location-config region="$S3_REGION",s3ForcePathStyle="true",s3Url="$S3_URL"

    # Safely discard local plain text secret files
    rm -f credentials-velero

    echo "=== Scheduling Automated Production Cron Engine Backups ==="
    # Deploys a daily backup engine running at midnight system time retaining copies for 7 days (168h)
    velero schedule create daily-cluster-backup \
        --schedule "0 0 * * *" \
        --ttl 168h0m0s \
        --include-namespaces="*"

    echo "SUCCESS: Velero initialized. Daily midnight engine backup schedule configured."
}


# ------------------------------------------------------------------------------
# TASK 3: PRIVATE CUSTOM DOMAIN AND EXTERNAL DNS INTEGRATION
# ------------------------------------------------------------------------------
setup_dns_and_domains() {
    echo "=== [TASK 3] Configuring Ingress Routers & Private CoreDNS Forwards ==="

    # 1. Update CoreDNS to forward queries out to your enterprise upstream DNS engine
    echo "Patching CoreDNS ConfigMap to forward resolving engines..."
    
    # Extract current CoreDNS layout safely
    kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' > Corefile.tmp

    # Append corporate/private upstream lookups right before wildcard forward paths
    if ! grep -q "$PRIVATE_DNS_IP" Corefile.tmp; then
        sed -i "/forward \. \/etc\/resolv.conf/i \    forward $DOMAIN_NAME $PRIVATE_DNS_IP {\n        max_concurrent 1000\n    }" Corefile.tmp
        kubectl create configmap coredns -n kube-system --from-file=Corefile=Corefile.tmp -o yaml --dry-run=client | kubectl apply -f -
        kubectl rollout restart deployment coredns -n kube-system
    fi
    rm -f Corefile.tmp

    # 2. Deploy custom Domain Ingress endpoints across internal components
    echo "Generating standard domain maps for your cluster stack..."
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: platform-dashboard-ingress
  namespace: monitoring
  annotations:
    ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  rules:
  - host: grafana.${DOMAIN_NAME}
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

    echo "------------------------------------------------------------------------"
    echo "SUCCESS: Domain maps complete!"
    echo "Map these entry pointers inside your external private DNS server config:"
    echo "grafana.${DOMAIN_NAME}   --> Point A-Record directly to VIP: $VIP"
    echo "------------------------------------------------------------------------"
}


# ==============================================================================
# MENU / ROUTING HANDLER ENGINE
# ==============================================================================
usage() {
    echo "Usage: $0 [worker | backup | dns | all]"
    echo "  worker : Output join strings for standard and isolated database nodes."
    echo "  backup : Install Velero engine and establish midnight snapshot schedules."
    echo "  dns    : Inject custom DNS paths and build a multi-domain route layer."
    echo "  all    : Execute all configuration routines listed above sequentially."
    exit 1
}

if [ $# -eq 0 ]; then
    usage
fi

case "$1" in
    worker)
        generate_worker_join
        ;;
    backup)
        setup_velero_backups
        ;;
    dns)
        setup_dns_and_domains
        ;;
    all)
        generate_worker_join
        setup_velero_backups
        setup_dns_and_domains
        ;;
    *)
        usage
        ;;
esac
