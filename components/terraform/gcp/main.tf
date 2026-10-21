terraform {
  required_providers {
    google = { source = "hashicorp/google", version = "~> 7.0" }
  }
}

provider "google" {
  project = var.project
  region  = var.region
  zone    = var.zone
  # cost allocation (billing export / reports: group by label); networks and firewalls have no labels.
  # Label values: lowercase letters, digits, - and _ only.
  default_labels = { "cost-usage" = var.stage }
}


locals {
  admin_cidrs = compact([var.admin_cidr, var.ci_cidr])
}

# --- network ---

resource "google_compute_network" "this" {
  name                    = "vpc-${var.stage}"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "this" {
  name          = "snet-${var.stage}"
  network       = google_compute_network.this.id
  ip_cidr_range = var.cidr
}

resource "google_compute_firewall" "internal" {
  name          = "fw-${var.stage}-internal"
  network       = google_compute_network.this.id
  source_ranges = [var.cidr]
  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "admin" {
  name          = "fw-${var.stage}-admin"
  network       = google_compute_network.this.id
  source_ranges = local.admin_cidrs
  allow {
    protocol = "tcp"
    ports    = [for p in var.admin_ports : tostring(p)]
  }
}

# --- compute ---

module "nodes" {
  source     = "../modules/nodes"
  sizes      = var.sizes
  node_types = var.node_types
  nodes      = var.nodes
}

resource "google_compute_instance" "node" {
  for_each     = module.nodes.nodes
  name         = "${var.stage}-${each.key}"
  machine_type = each.value.size
  # resizing a node type stops/starts its VMs
  allow_stopping_for_update = true
  metadata                  = { ssh-keys = "ubuntu:${file(pathexpand(var.ssh_public_key_file))}" }
  boot_disk {
    initialize_params {
      image  = var.image
      size   = each.value.disk_size
      labels = { "cost-usage" = var.stage } # boot disk does not get provider default_labels
    }
  }
  network_interface {
    subnetwork = google_compute_subnetwork.this.id
    access_config {}
  }
}
