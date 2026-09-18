variable "elasticsearch_endpoint" {
  description = "Elasticsearch URL the collector exports to. It must be reachable from inside the Kubernetes cluster, e.g. https://host.minikube.internal:9200 for an Elasticsearch running on the minikube host."
  type        = string
}

variable "elasticsearch_api_key" {
  description = "Elasticsearch API key (the base64 `encoded` value returned by the create API key API)."
  type        = string
  sensitive   = true
}

variable "elasticsearch_insecure_skip_verify" {
  description = "Skip TLS certificate verification when connecting to Elasticsearch. Set to true for a local Elasticsearch with a self-signed certificate."
  type        = bool
  default     = false
}

variable "elastic_agent_version" {
  description = "Elastic Agent (EDOT Collector) image tag. See https://github.com/elastic/elastic-agent/releases."
  type        = string
  default     = "9.5.4"
}

variable "kube_stack_chart_version" {
  description = "opentelemetry-kube-stack Helm chart version. Matches the version used in the Elastic Kubernetes quickstart."
  type        = string
  default     = "0.16.0"
}

variable "cluster_name" {
  description = "Value for the k8s.cluster.name resource attribute. The chart cannot auto-detect a name on local clusters."
  type        = string
  default     = "minikube"
}

variable "namespace" {
  description = "Namespace to install the operator and collector into."
  type        = string
  default     = "opentelemetry-operator-system"
}

variable "release_name" {
  description = "Helm release name."
  type        = string
  default     = "opentelemetry-kube-stack"
}

variable "kubeconfig_path" {
  description = "Path to the kubeconfig file."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "kubeconfig context to use. Defaults to the current context."
  type        = string
  default     = null
}
