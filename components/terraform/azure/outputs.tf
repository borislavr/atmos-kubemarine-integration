output "nodes" {
  value = [for k, v in azurerm_linux_virtual_machine.node : merge({
    name             = k
    address          = azurerm_public_ip.node[k].ip_address
    internal_address = azurerm_network_interface.node[k].private_ip_address
  }, module.nodes.kubemarine[k])]
}
