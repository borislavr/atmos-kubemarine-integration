# Resolves cluster nodes against node types: node = its type + per-node overrides.
# Shared by all cloud components so the node model is defined once.

variable "node_types" {
  description = "Node profiles: kubemarine roles, VM size, disk, labels, taints"
  type = map(object({
    roles     = list(string)
    size      = string
    disk_size = optional(number, 50)
    labels    = optional(map(string), {})
    taints    = optional(list(string), [])
  }))
}

variable "nodes" {
  description = "Cluster nodes: name -> type (+ optional overrides of the type's fields)"
  type = map(object({
    type      = string
    size      = optional(string)
    disk_size = optional(number)
    labels    = optional(map(string), {})
    taints    = optional(list(string))
  }))
  validation {
    condition     = alltrue([for n in values(var.nodes) : contains(keys(var.node_types), n.type)])
    error_message = "Every node `type` must be a key of node_types."
  }
}

locals {
  nodes = { for k, n in var.nodes : k => {
    roles     = var.node_types[n.type].roles
    size      = coalesce(n.size, var.node_types[n.type].size)
    disk_size = coalesce(n.disk_size, var.node_types[n.type].disk_size)
    labels    = merge(var.node_types[n.type].labels, n.labels)
    taints    = n.taints != null ? n.taints : var.node_types[n.type].taints
  } }
}

# Resolved nodes for creating VMs.
output "nodes" {
  value = local.nodes
}

# Node fields for kubemarine cluster.yaml (empty labels/taints omitted).
output "kubemarine" {
  value = { for k, n in local.nodes : k => merge(
    { roles = n.roles },
    length(n.labels) > 0 ? { labels = n.labels } : {},
    length(n.taints) > 0 ? { taints = n.taints } : {},
  ) }
}
