account_file = "/etc/kubestack-account.json"
flannel_backend = "vxlan"
flannel_network = "10.10.0.0/16"
etcd_image = "coreos-alpha-884-0-0"
kubernetes_image = "kubernetes"
portal_net = "10.200.0.0/16"
region = "us-central1"
token_auth_file = "secrets/tokens.csv"
worker_count = 3
zone = "us-central1-a"
cluster_name = "kubestack-testing"

public_key_path = "~/.ssh/id_rsa.pub"
network_name = "internal"
floatingip_pool = "external"

project = "kubestack"
etcd_flavor = "m1.medium"
