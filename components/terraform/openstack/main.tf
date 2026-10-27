terraform {
  required_providers {
    openstack = { source = "terraform-provider-openstack/openstack", version = "~> 3.0" }
  }
}

# Auth: OS_CLOUD (clouds.yaml) from the stack `env`, or OS_* env vars.
provider "openstack" {}

data "openstack_networking_network_v2" "external" {
  name = var.external_network
}


locals {
  admin_cidrs = compact([var.admin_cidr, var.ci_cidr])
  # cost allocation: Neutron/Nova tags are plain strings (key=value by convention); the VM also gets it as metadata
  tags = ["cost-usage=${var.stage}"]
}

# --- network ---

resource "openstack_networking_network_v2" "this" {
  name = "net-${var.stage}"
  tags = local.tags
}

resource "openstack_networking_subnet_v2" "this" {
  name            = "snet-${var.stage}"
  tags            = local.tags
  network_id      = openstack_networking_network_v2.this.id
  cidr            = var.cidr
  dns_nameservers = var.dns_nameservers
}

resource "openstack_networking_router_v2" "this" {
  name                = "rtr-${var.stage}"
  tags                = local.tags
  external_network_id = data.openstack_networking_network_v2.external.id
}

resource "openstack_networking_router_interface_v2" "this" {
  router_id = openstack_networking_router_v2.this.id
  subnet_id = openstack_networking_subnet_v2.this.id
}

resource "openstack_networking_secgroup_v2" "this" {
  name = "sg-${var.stage}"
  tags = local.tags
}

resource "openstack_networking_secgroup_rule_v2" "internal" {
  for_each          = toset(["tcp", "udp", "icmp"])
  security_group_id = openstack_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = each.key
  remote_ip_prefix  = var.cidr
}

resource "openstack_networking_secgroup_rule_v2" "admin" {
  for_each          = { for pc in setproduct(var.admin_ports, local.admin_cidrs) : "${pc[0]}-${pc[1]}" => pc }
  security_group_id = openstack_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = each.value[0]
  port_range_max    = each.value[0]
  remote_ip_prefix  = each.value[1]
}

# --- compute ---

module "nodes" {
  source     = "../modules/nodes"
  sizes      = var.sizes
  node_types = var.node_types
  nodes      = var.nodes
}

resource "openstack_compute_keypair_v2" "this" {
  name       = "kp-${var.stage}"
  public_key = var.ssh_public_key
}

resource "openstack_networking_port_v2" "node" {
  for_each           = module.nodes.nodes
  name               = "port-${var.stage}-${each.key}"
  tags               = local.tags
  network_id         = openstack_networking_network_v2.this.id
  security_group_ids = [openstack_networking_secgroup_v2.this.id]
  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.this.id
  }
}

resource "openstack_compute_instance_v2" "node" {
  for_each    = module.nodes.nodes
  name        = "${var.stage}-${each.key}"
  tags        = local.tags
  metadata    = { "cost-usage" = var.stage }
  image_name  = var.image
  flavor_name = each.value.size # disk size comes from the flavor; node type disk_size is ignored here
  # by name, not reference: a rotated key replaces the keypair, which must not replace the VMs (atmos sshkey rotate
  # puts the new key on running nodes); VMs created later get the new key
  key_pair   = "kp-${var.stage}"
  depends_on = [openstack_compute_keypair_v2.this]
  network {
    port = openstack_networking_port_v2.node[each.key].id
  }
}

resource "openstack_networking_floatingip_v2" "node" {
  for_each = module.nodes.nodes
  pool     = var.external_network
  tags     = local.tags
}

resource "openstack_networking_floatingip_associate_v2" "node" {
  for_each    = module.nodes.nodes
  floating_ip = openstack_networking_floatingip_v2.node[each.key].address
  port_id     = openstack_networking_port_v2.node[each.key].id
  depends_on  = [openstack_networking_router_interface_v2.this]
}
