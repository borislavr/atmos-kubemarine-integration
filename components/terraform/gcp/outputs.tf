output "nodes" {
  value = [for k, v in google_compute_instance.node : merge({
    name             = k
    address          = v.network_interface[0].access_config[0].nat_ip
    internal_address = v.network_interface[0].network_ip
  }, module.nodes.kubemarine[k])]
}
