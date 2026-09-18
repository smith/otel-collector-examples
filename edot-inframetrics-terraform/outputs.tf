output "namespace" {
  description = "Namespace the operator and collector run in."
  value       = kubernetes_namespace_v1.otel.metadata[0].name
}

output "collector_daemonset" {
  description = "Name of the DaemonSet created by the OpenTelemetry Operator for the EDOT collector."
  value       = "opentelemetry-kube-stack-daemon-collector"
}

output "collector_logs_command" {
  description = "Command to tail the collector logs."
  value       = "kubectl logs -n ${kubernetes_namespace_v1.otel.metadata[0].name} daemonset/opentelemetry-kube-stack-daemon-collector -f"
}
