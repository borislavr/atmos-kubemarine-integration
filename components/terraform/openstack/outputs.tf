output "nodes" {
  value = [for k, v in openstack_networking_port_v2.node : merge({
    name             = k
    address          = openstack_networking_floatingip_v2.node[k].address
    internal_address = v.all_fixed_ips[0]
  }, module.nodes.kubemarine[k])]
}
