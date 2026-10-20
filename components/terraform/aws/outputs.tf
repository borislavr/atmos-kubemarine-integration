output "nodes" {
  value = [for k, v in aws_instance.node : merge({
    name             = k
    address          = v.public_ip
    internal_address = v.private_ip
  }, module.nodes.kubemarine[k])]
}
