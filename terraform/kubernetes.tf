resource "null_resource" "discovery_url_template" {
    provisioner "local-exec" {
        command = "curl -s 'https://discovery.etcd.io/new?size=1' > templates/discovery_url"
    }
}

resource "null_resource" "generate_ssl" {
    count = "${var.generate_ssl}"
    provisioner "local-exec" {
        command = "bash ssl/generate-ssl.sh"
    }
}

resource "template_file" "discovery_url" {
    template = "templates/discovery_url"
    depends_on = [
        "null_resource.discovery_url_template"
    ]
}

resource "template_file" "controller_cloud_init" {
    template = "templates/cloud-init"
    vars {
        flannel_network = "${var.flannel_network}"
        flannel_backend = "${var.flannel_backend}"
        etcd_servers = "http://127.0.0.1:2379"
        cluster_token = "${var.cluster_name}"
        discovery_url = "${template_file.discovery_url.rendered}"
    }
}

resource "template_file" "compute_cloud_init" {
    template = "templates/cloud-init"
    vars {
        flannel_network = "${var.flannel_network}"
        flannel_backend = "${var.flannel_backend}"
        etcd_servers = "${join(",", "${formatlist("http://%s:2379", openstack_compute_instance_v2.controller.*.network.0.fixed_ip_v4)}")}"
        cluster_token = "${var.cluster_name}"
        discovery_url = "${template_file.discovery_url.rendered}"
    }
}

resource "openstack_networking_floatingip_v2" "controller" {
  count = "1"
  pool = "${var.floatingip_pool}"
}

resource "openstack_networking_floatingip_v2" "compute" {
  count = "${var.compute_count}"
  pool = "${var.floatingip_pool}"
}

resource "openstack_compute_keypair_v2" "kubernetes" {
  name = "${var.project}"
  public_key = "${file(var.public_key_path)}"
}

resource "openstack_compute_instance_v2" "controller" {
    name = "${var.cluster_name}-controller${count.index}"
    count = "1"
    image_name = "${var.kubernetes_image}"
    flavor_name = "${var.kubernetes_flavor}"
    key_pair = "${openstack_compute_keypair_v2.kubernetes.name}"
    network {
        name = "${var.network_name}"
    }
    security_groups = [
        "${openstack_compute_secgroup_v2.kubernetes_base.name}",
        "${openstack_compute_secgroup_v2.kubernetes_controller.name}"
    ]
    floating_ip = "${element(openstack_networking_floatingip_v2.controller.*.address, count.index)}"
    user_data = "${template_file.controller_cloud_init.rendered}"
    provisioner "file" {
        source = "ssl"
        destination = "/tmp/kubernetes-ssl"
        connection {
            user = "core"
        }
    }
    provisioner "file" {
        source = "files/controller"
        destination = "/tmp/stage"
        connection {
            user = "core"
        }
    }
    provisioner "remote-exec" {
        inline = [
            "sudo mkdir -p /opt/bin",
            "sudo wget -q -O /opt/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/${var.kubectl_version}/bin/linux/amd64/kubectl",
            "sudo chmod 0755 /opt/bin/kubectl",
            "sudo mkdir -p /etc/kubernetes/ssl",
            "cd /tmp/kubernetes-ssl",
            "echo DNS.1 = kubernetes >> openssl.cnf",
            "echo DNS.2 = kubernetes.local >> openssl.cnf",
            "echo 'IP.1 = ${element(openstack_networking_floatingip_v2.controller.*.address, count.index)}' >> openssl.cnf",
            "echo 'IP.3 = ${cidrhost(var.portal_net, count.index + 1)}' >> openssl.cnf",
            "echo 'IP.2 = ${self.network.0.fixed_ip_v4}' >> openssl.cnf",
            "openssl genrsa -out controller-key.pem 2048",
            "openssl req -new -key controller-key.pem -out controller.csr -subj '/CN=kubernetes-controller' -config openssl.cnf",
            "openssl x509 -req -in controller.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out controller.pem -days 365 -extensions v3_req -extfile openssl.cnf",
            "sudo mv controller*.pem /etc/kubernetes/ssl",
            "sudo mv admin*.pem /etc/kubernetes/ssl",
            "sudo mv ca.pem /etc/kubernetes/ssl",
            "sudo chown root:root /etc/kubernetes/ssl/*; sudo chmod 0600 /etc/kubernetes/ssl/*-key.pem",
            "sudo chown core:core /etc/kubernetes/ssl/admin-key.pem",
            "# rm -rf /tmp/kubernetes-ssl",
            "mkdir -p /tmp/stage",
            "sed -i 's/MY_IP/${self.network.0.fixed_ip_v4}/' /tmp/stage/*",
            "sed -i 's/ADVERTISE_IP/${element(openstack_networking_floatingip_v2.controller.*.address, count.index)}/' /tmp/stage/*",
            "sed -i 's|PORTAL_NET|${var.portal_net}|' /tmp/stage/*",
            "sed -i 's|CLUSTER_DNS|${cidrhost(var.portal_net, 200)}|' /tmp/stage/*",
            "sudo mkdir -p /etc/kubernetes/manifests",
            "sudo mv /tmp/stage/*.yaml /etc/kubernetes/manifests/",
            "sudo mv /tmp/stage/*.service /etc/systemd/system/",
            "rm -rf /tmp/kubernetes-ssl",
            "rm -rf /tmp/stage",
            "sudo systemctl daemon-reload",
            "sudo systemctl enable kube-kubelet",
            "sudo systemctl start kube-kubelet",
            "echo Wait until API comes online...",
            "while ! curl http://127.0.0.1:8080/version; do sleep 60; done",
            "curl -XPOST -d'{\"apiVersion\":\"v1\",\"kind\":\"Namespace\",\"metadata\":{\"name\":\"kube-system\"}}' \"http://127.0.0.1:8080/api/v1/namespaces\"",
        ]
        connection {
            user = "core"
        }
    }
    depends_on = [
        "template_file.controller_cloud_init",
        "null_resource.generate_ssl",
    ]
}

resource "openstack_compute_instance_v2" "compute" {
    name = "${var.cluster_name}-compute${count.index}"
    count = "${var.compute_count}"
    image_name = "${var.kubernetes_image}"
    flavor_name = "${var.kubernetes_flavor}"
    floating_ip = "${element(openstack_networking_floatingip_v2.compute.*.address, count.index)}"
    key_pair = "${openstack_compute_keypair_v2.kubernetes.name}"
    network {
        name = "${var.network_name}"
    }
    security_groups = [ "${openstack_compute_secgroup_v2.kubernetes_base.name}" ]
    user_data = "${template_file.compute_cloud_init.rendered}"
    provisioner "file" {
        source = "ssl"
        destination = "/tmp/kubernetes-ssl"
        connection {
            user = "core"
        }
    }
    provisioner "file" {
        source = "files/compute"
        destination = "/tmp/stage"
        connection {
            user = "core"
        }
    }
    provisioner "remote-exec" {
        inline = [
            "sudo mkdir -p /opt/bin",
            "sudo wget -q -O /opt/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/${var.kubectl_version}/bin/linux/amd64/kubectl",
            "sudo chmod 0755 /opt/bin/kubectl",
            "sudo mkdir -p /etc/kubernetes/ssl",
            "cd /tmp/kubernetes-ssl",
            "sudo mkdir -p /etc/kubernetes/ssl",
            "echo 'IP.1 = ${self.network.0.fixed_ip_v4}' >> openssl.cnf",
            "openssl genrsa -out compute-key.pem 2048",
            "openssl req -new -key compute-key.pem -out compute.csr -subj '/CN=kubernetes-compute' -config openssl.cnf",
            "openssl x509 -req -in compute.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out compute.pem -days 365 -extensions v3_req -extfile openssl.cnf",
            "sudo mv compute-key.pem /etc/kubernetes/ssl",
            "sudo mv compute.pem /etc/kubernetes/ssl",
            "sudo mv ca.pem /etc/kubernetes/ssl",
            "sudo chown root:root /etc/kubernetes/ssl/*; sudo chmod 0600 /etc/kubernetes/ssl/*-key.pem",
            "rm -rf /tmp/kubernetes-ssl",
            "mkdir -p /tmp/stage",
            "sed -i 's/MY_IP/${self.network.0.fixed_ip_v4}/' /tmp/stage/*",
            "sed -i 's/ADVERTISE_IP/${element(openstack_networking_floatingip_v2.compute.*.address, count.index)}/' /tmp/stage/*",
            "sed -i 's/CONTROLLER_HOST/${openstack_compute_instance_v2.controller.0.network.0.fixed_ip_v4}/' /tmp/stage/*",
            "sed -i 's|PORTAL_NET|${var.portal_net}|' /tmp/stage/*",
            "sed -i 's|CLUSTER_DNS|${cidrhost(var.portal_net, 200)}|' /tmp/stage/*",
            "sudo mkdir -p /etc/kubernetes/manifests",
            "sudo mv /tmp/stage/*.yaml /etc/kubernetes/manifests/",
            "sudo mv /tmp/stage/*.service /etc/systemd/system/",
            "sudo mv /tmp/stage/compute-kubeconfig.yaml.config /etc/kubernetes/compute-kubeconfig.yaml",
            "rm -rf /tmp/kubernetes-ssl",
            "rm -rf /tmp/stage",
            "sudo systemctl daemon-reload",
            "sudo systemctl enable kube-kubelet",
            "sudo systemctl start kube-kubelet",
        ]
        connection {
            user = "core"
        }
    }
    depends_on = [
        "template_file.compute_cloud_init",
        "openstack_compute_instance_v2.controller"
    ]
}

resource "null_resource" "controller" {
   provisioner "remote-exec" {
        inline = [
            "/opt/bin/kubectl config set-cluster ${var.cluster_name} --certificate-authority=/etc/kubernetes/ssl/ca.pem \\",
            "  --server=https://${openstack_compute_instance_v2.controller.0.network.0.fixed_ip_v4}:443",
            "/opt/bin/kubectl config set-credentials ${var.kubernetes_user} \\",
            "  --certificate-authority=/etc/kubernetes/ssl/ca.pem \\",
            "  --client-key=/etc/kubernetes/ssl/admin-key.pem \\",
            "  --client-certificate=/etc/kubernetes/ssl/admin.pem",
            "/opt/bin/kubectl config set-context kubernetes --cluster=${var.cluster_name} --user=${var.kubernetes_user}",
            "/opt/bin/kubectl config use-context kubernetes",
        ]
        connection {
            user = "core"
            host = "${openstack_networking_floatingip_v2.controller.0.address}"
        }
    }
    depends_on = [
        "openstack_compute_instance_v2.controller",
        "openstack_compute_instance_v2.compute",
    ]
}

output "kubernetes-controller" {
    value = "$ ssh -A core@${openstack_networking_floatingip_v2.controller.0.address}"
}
