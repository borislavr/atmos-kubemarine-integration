variable "stage" { type = string }
variable "admin_cidr" { type = string }
variable "sizes" {
  type        = map(string)
  default     = {}
  description = "Size classes -> VM sizes of this provider, see modules/nodes"
}
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
variable "ci_cidr" {
  type        = string
  default     = ""
  description = "Extra admin source, set by CI (TF_VAR_ci_cidr) for the duration of a workflow run"
}
variable "admin_ports" { default = [22, 6443] }
variable "cidr" { default = "10.10.0.0/24" }
variable "dns_nameservers" { default = ["8.8.8.8", "1.1.1.1"] }
variable "ssh_public_key" {
  type        = string
  description = "OpenSSH public key of the `ubuntu` user, from the stack secret SSH_PUBLIC_KEY (atmos sshkey ensure)"
}
