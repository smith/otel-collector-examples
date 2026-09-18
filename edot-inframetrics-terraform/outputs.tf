output "namespace" {
  description = "Namespace the operator and collectors run in."
  value       = kubernetes_namespace_v1.otel.metadata[0].name
}

output "daemon_collector" {
  description = "DaemonSet created by the OpenTelemetry Operator for the node-level collector (kubelet pod metrics)."
  value       = "daemonset/opentelemetry-kube-stack-daemon-collector"
}

output "cluster_collector" {
  description = "Deployment created by the OpenTelemetry Operator for the cluster-level collector (node metrics)."
  value       = "deployment/opentelemetry-kube-stack-cluster-stats-collector"
}

output "collector_logs_commands" {
  description = "Commands to tail the collector logs."
  value = [
    "kubectl logs -n ${kubernetes_namespace_v1.otel.metadata[0].name} daemonset/opentelemetry-kube-stack-daemon-collector -f",
    "kubectl logs -n ${kubernetes_namespace_v1.otel.metadata[0].name} deployment/opentelemetry-kube-stack-cluster-stats-collector -f",
  ]
}
