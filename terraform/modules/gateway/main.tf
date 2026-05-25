# Módulo: GKE Gateway API
# Ref CAF: Standard 19 - High Availability Architecture

variable "gateway_name" { type = string }
variable "namespace" { type = string }
variable "cert_map" { type = string }
variable "gateway_class" { type = string }

resource "kubernetes_manifest" "gateway" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = var.gateway_name
      namespace = var.namespace
      labels = {
        "app.kubernetes.io/part-of" = "financiero-platform"
      }
      annotations = {
        "networking.gke.io/certmap" = var.cert_map
      }
    }
    spec = {
      gatewayClassName = var.gateway_class
      listeners = [
        {
          name     = "https"
          port     = 443
          protocol = "HTTPS"
          allowedRoutes = {
            namespaces = { from = "All" }
          }
        },
        {
          name     = "http-redirect"
          port     = 80
          protocol = "HTTP"
          allowedRoutes = {
            namespaces = { from = "All" }
          }
        }
      ]
    }
  }
}

resource "kubernetes_manifest" "http_redirect" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "http-to-https-redirect"
      namespace = var.namespace
    }
    spec = {
      parentRefs = [{
        name        = var.gateway_name
        namespace   = var.namespace
        sectionName = "http-redirect"
      }]
      rules = [{
        filters = [{
          type = "RequestRedirect"
          requestRedirect = {
            scheme     = "https"
            statusCode = 301
          }
        }]
      }]
    }
  }
}
