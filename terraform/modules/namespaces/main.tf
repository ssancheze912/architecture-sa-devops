# Módulo: Kubernetes Namespaces
# Ref CAF: Standard 04 - Resource Organization

variable "namespaces" { type = list(string) }
variable "labels" { type = map(string) }

resource "kubernetes_namespace" "ns" {
  for_each = toset(var.namespaces)

  metadata {
    name   = each.value
    labels = merge(var.labels, {
      "app.kubernetes.io/component" = each.value
    })
  }
}
