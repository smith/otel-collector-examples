resource "kubernetes_namespace_v1" "otel" {
  metadata {
    name = var.namespace
  }
}

# Same secret name and keys as the Elastic Kubernetes quickstart, so the
# collector env config in values.yaml matches the upstream EDOT values file.
resource "kubernetes_secret_v1" "elastic" {
  metadata {
    name      = "elastic-secret-otel"
    namespace = kubernetes_namespace_v1.otel.metadata[0].name
  }

  data = {
    elastic_endpoint = var.elasticsearch_endpoint
    elastic_api_key  = var.elasticsearch_api_key
  }
}

resource "helm_release" "kube_stack" {
  name       = var.release_name
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-kube-stack"
  version    = var.kube_stack_chart_version
  namespace  = kubernetes_namespace_v1.otel.metadata[0].name

  # values.yaml is plain Helm values and can also be used directly with
  # `helm install --values`. The second entry layers the Terraform variables on top.
  values = [
    file("${path.module}/values.yaml"),
    yamlencode({
      clusterName = var.cluster_name
      defaultCRConfig = {
        image = {
          tag = var.elastic_agent_version
        }
      }
      collectors = {
        daemon = {
          config = {
            exporters = {
              elasticsearch = {
                tls = {
                  insecure_skip_verify = var.elasticsearch_insecure_skip_verify
                }
              }
            }
          }
        }
      }
    }),
  ]

  wait    = true
  timeout = 600

  depends_on = [kubernetes_secret_v1.elastic]
}
