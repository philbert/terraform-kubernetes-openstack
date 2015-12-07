output "kubernetes-api-server" {
    value = "https://${openstack_networking_floatingip_v2.controller.0.address}:6443"
}

resource "template_file" "etcd_cloud_init" {
    filename = "etcd-cloud-init"
    vars {
        cluster_token = "${var.cluster_name}"
        discovery_url = "${var.discovery_url}"
    }
}

resource "template_file" "controller_cloud_init" {
    filename = "controller-cloud-init"
    vars {
        flannel_network = "${var.flannel_network}"
        flannel_backend = "${var.flannel_backend}"
        etcd_servers = "http://127.0.0.1:2379"
        cluster_token = "${var.cluster_name}"
        discovery_url = "${var.discovery_url}"
    }
}

resource "template_file" "compute_cloud_init" {
    filename = "compute-cloud-init"
    vars {
        flannel_network = "${var.flannel_network}"
        flannel_backend = "${var.flannel_backend}"
        etcd_servers = "http://127.0.0.1:2379"
        cluster_token = "${var.cluster_name}"
        discovery_url = "${var.discovery_url}"
    }
}

resource "template_file" "kubernetes" {
    filename = "kubernetes.env"
    vars {
        api_servers = "http://${openstack_networking_floatingip_v2.controller.0.address}:8080"
        etcd_servers = "http://127.0.0.1:2379"
        flannel_backend = "${var.flannel_backend}"
        flannel_network = "${var.flannel_network}"
        portal_net = "${var.portal_net}"
    }
}

resource "openstack_networking_floatingip_v2" "controller" {
  count = "1"
  pool = "${var.floatingip_pool}"
}

resource "openstack_compute_keypair_v2" "kubestack" {
  name = "${var.project}"
  public_key = "${file(var.public_key_path)}"
}

resource "openstack_compute_secgroup_v2" "kubernetes_controller" {
  name = "${var.project}_kubernetes_api"
  description = "kubestack Security Group"
  rule {
    ip_protocol = "tcp"
    from_port = "22"
    to_port = "22"
    cidr = "0.0.0.0/0"
  }
  rule {
    ip_protocol = "tcp"
    from_port = "6443"
    to_port = "6443"
    cidr = "0.0.0.0/0"
  }
  rule {
    ip_protocol = "icmp"
    from_port = "-1"
    to_port = "-1"
    cidr = "0.0.0.0/0"
  }
}

resource "openstack_compute_secgroup_v2" "kubernetes_internal" {
  name = "${var.project}_kubernetes_internal"
  description = "kubestack Security Group"
  rule {
    ip_protocol = "tcp"
    from_port = "22"
    to_port = "22"
    cidr = "0.0.0.0/0"
  }
  rule {
    ip_protocol = "tcp"
    from_port = "6443"
    to_port = "6443"
    cidr = "0.0.0.0/0"
  }
  rule {
    ip_protocol = "icmp"
    from_port = "-1"
    to_port = "-1"
    cidr = "0.0.0.0/0"
  }
  rule {
    ip_protocol = "icmp"
    from_port = "-1"
    to_port = "-1"
    self = true
  }
  rule {
    ip_protocol = "tcp"
    from_port = "1"
    to_port = "65535"
    self = true
  }
  rule {
    ip_protocol = "udp"
    from_port = "1"
    to_port = "65535"
    self = true
  }
}

#resource "openstack_compute_instance_v2" "etcd" {
#  name = "${var.cluster_name}-etcd${count.index}"
#  count = "1"
#  image_name = "${var.etcd_image}"
#  flavor_name = "${var.etcd_flavor}"
#  key_pair = "${openstack_compute_keypair_v2.kubestack.name}"
#  network {
#    name = "${var.network_name}"
#  }
#  security_groups = [ "${openstack_compute_secgroup_v2.kubernetes_internal.name}" ]
#  user_data = "${template_file.etcd_cloud_init.rendered}"
#  depends_on = [
#      "template_file.etcd_cloud_init",
#  ]
#}

resource "openstack_compute_instance_v2" "controller" {
  name = "${var.cluster_name}-controller${count.index}"
  count = "1"
  image_name = "${var.kubernetes_image}"
  flavor_name = "${var.kubernetes_flavor}"
  key_pair = "${openstack_compute_keypair_v2.kubernetes_api.name}"
  network {
    name = "${var.network_name}"
  }
  security_groups = [
    "${openstack_compute_secgroup_v2.kubernetes_internal.name}",
    "${openstack_compute_secgroup_v2.kubernetes_controller.name}"
  ]
  floating_ip = "${element(openstack_networking_floatingip_v2.controller.*.address, count.index)}"
  user_data = "${template_file.controller_cloud_init.rendered}"
  provisioner "remote-exec" {
    inline = [
      "sudo cat <<'EOF' > /tmp/kubernetes.env\n${template_file.kubernetes.rendered}\nEOF",
      "sudo mv /tmp/kubernetes.env /etc/kubernetes.env",
      "sudo mkdir -p /etc/kubernetes",
      "sudo systemctl enable flanneld",
      "sudo systemctl enable docker",
      "sudo systemctl enable kube-apiserver",
      "sudo systemctl enable kube-controller-manager",
      "sudo systemctl enable kube-scheduler",
      "sudo systemctl start flanneld",
      "sudo systemctl start docker",
      "sudo systemctl start kube-apiserver",
      "sudo systemctl start kube-controller-manager",
      "sudo systemctl start kube-scheduler"
    ]
    connection {
        user = "core"
        agent = true
    }
  }
  depends_on = [
      "template_file.controller_cloud_init",
  ]
}

resource "openstack_compute_instance_v2" "compute" {
  name = "${var.cluster_name}-compute${count.index}"
  count = "1"
  image_name = "${var.kubernetes_image}"
  flavor_name = "${var.kubernetes_flavor}"
  key_pair = "${openstack_compute_keypair_v2.kubestack.name}"
  network {
    name = "${var.network_name}"
  }
  security_groups = [ "${openstack_compute_secgroup_v2.kubernetes_internal.name}" ]
  user_data = "${template_file.compute_cloud_init.rendered}"
  provisioner "remote-exec" {
    inline = [
      "sudo cat <<'EOF' > /tmp/kubernetes.env\n${template_file.kubernetes.rendered}\nEOF",
      "sudo mv /tmp/kubernetes.env /etc/kubernetes.env",
      "sudo systemctl enable flanneld",
      "sudo systemctl enable docker",
      "sudo systemctl enable kube-kubelet",
      "sudo systemctl enable kube-proxy",
      "sudo systemctl start flanneld",
      "sudo systemctl start docker",
      "sudo systemctl start kube-kubelet",
      "sudo systemctl start kube-proxy"
    ]
    connection {
        user = "core"
        agent = true
        bastion_host = "${openstack_networking_floatingip_v2.controller.0.address}"
    }
  }
  depends_on = [
      "template_file.compute_cloud_init",
      "openstack_compute_instance_v2.controller"
  ]
}
