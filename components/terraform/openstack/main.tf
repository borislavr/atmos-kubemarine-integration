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
}

# --- network ---

resource "openstack_networking_network_v2" "this" {
  name = var.stage
}

resource "openstack_networking_subnet_v2" "this" {
  name            = var.stage
  network_id      = openstack_networking_network_v2.this.id
  cidr            = var.cidr
  dns_nameservers = var.dns_nameservers
}

resource "openstack_networking_router_v2" "this" {
  name                = var.stage
  external_network_id = data.openstack_networking_network_v2.external.id
}

resource "openstack_networking_router_interface_v2" "this" {
  router_id = openstack_networking_router_v2.this.id
  subnet_id = openstack_networking_subnet_v2.this.id
}

resource "openstack_networking_secgroup_v2" "this" {
  name = var.stage
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
  name       = var.stage
  public_key = file(pathexpand(var.ssh_public_key_file))
}

resource "openstack_networking_port_v2" "node" {
  for_each           = module.nodes.nodes
  name               = "${var.stage}-${each.key}"
  network_id         = openstack_networking_network_v2.this.id
  security_group_ids = [openstack_networking_secgroup_v2.this.id]
  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.this.id
  }
}

resource "openstack_compute_instance_v2" "node" {
  for_each    = module.nodes.nodes
  name        = "${var.stage}-${each.key}"
  image_name  = var.image
  flavor_name = each.value.size # disk size comes from the flavor; node type disk_size is ignored here
  key_pair    = openstack_compute_keypair_v2.this.name
  network {
    port = openstack_networking_port_v2.node[each.key].id
  }
}

resource "openstack_networking_floatingip_v2" "node" {
  for_each = module.nodes.nodes
  pool     = var.external_network
}

resource "openstack_networking_floatingip_associate_v2" "node" {
  for_each    = module.nodes.nodes
  floating_ip = openstack_networking_floatingip_v2.node[each.key].address
  port_id     = openstack_networking_port_v2.node[each.key].id
  depends_on  = [openstack_networking_router_interface_v2.this]
}
