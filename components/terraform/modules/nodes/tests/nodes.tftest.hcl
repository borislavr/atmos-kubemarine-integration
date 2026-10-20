# terraform test (from components/terraform/modules/nodes): type defaults, per-node overrides, unknown type.

variables {
  node_types = {
    worker = { roles = ["worker"], size = "small", labels = { tier = "app" } }
    infra  = { roles = ["worker"], size = "medium", disk_size = 100, taints = ["infra=true:NoSchedule"] }
  }
  nodes = {
    worker-1 = { type = "worker" }
    worker-2 = { type = "worker", size = "large", labels = { zone = "b" } }
    infra-1  = { type = "infra" }
  }
}

run "resolves_types_and_overrides" {
  command = plan

  assert {
    condition     = output.nodes["worker-1"].size == "small" && output.nodes["worker-1"].disk_size == 50
    error_message = "type defaults not applied"
  }
  assert {
    condition     = output.nodes["worker-2"].size == "large" && jsonencode(output.nodes["worker-2"].labels) == jsonencode({ tier = "app", zone = "b" })
    error_message = "per-node overrides not applied"
  }
  assert {
    condition     = jsonencode(output.kubemarine["infra-1"]) == jsonencode({ roles = ["worker"], taints = ["infra=true:NoSchedule"] })
    error_message = "kubemarine fields wrong (empty labels must be omitted)"
  }
  assert {
    condition     = jsonencode(output.kubemarine["worker-1"]) == jsonencode({ labels = { tier = "app" }, roles = ["worker"] })
    error_message = "kubemarine fields wrong (empty taints must be omitted)"
  }
}

run "rejects_unknown_type" {
  command = plan

  variables {
    nodes = { gpu-1 = { type = "gpu" } }
  }

  expect_failures = [var.nodes]
}
