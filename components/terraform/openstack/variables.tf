variable "stage" { type = string }
variable "admin_cidr" { type = string }
variable "node_types" {
  type        = any
  description = "Node profiles, see modules/nodes"
}
variable "nodes" {
  type        = any
  description = "name -> { type, overrides }, see modules/nodes"
}
variable "external_network" { type = string }
variable "image" { type = string }
variable "admin_ports" { default = [22, 6443] }
variable "cidr" { default = "10.10.0.0/24" }
variable "dns_nameservers" { default = ["8.8.8.8", "1.1.1.1"] }
variable "ssh_public_key_file" { default = "~/.ssh/id_ed25519.pub" }
