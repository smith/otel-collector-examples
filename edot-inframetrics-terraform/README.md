# EDOT Inframetrics Terraform example

Example OpenTelemetry collector setup using:

- [Elastic Agent OpenTelemetry collector](https://www.elastic.co/docs/reference/edot-collector)
- [Terraform](https://developer.hashicorp.com/terraform)
- [Elastic Infra Metrics Processor](https://github.com/elastic/opentelemetry-collector-components/blob/main/processor/elasticinframetricsprocessor/README.md)

This configuration can be used if you want to use the [infrastructure inventory in Kibana](https://www.elastic.co/docs/solutions/observability/infra-and-hosts/view-infrastructure-metrics-by-resource-type) for Kubernetes pod metrics. The pod metrics view uses the metrics specified by the [Elastic Kubernetes integration](https://www.elastic.co/docs/reference/integrations/kubernetes) and the [Metricbeat Kubernetes module](https://www.elastic.co/docs/reference/beats/metricbeat/metricbeat-module-kubernetes).

The infrastructure inventory supports showing metrics for different types of entities with different metrics and schemas. For host metrics, both the Elastic system integration and OpenTelemetry host metrics are supported. For pod metrics, only Elastic Kubernetes integration metrics are supported.

The Elastic Infra Metrics Processor processes metrics collected from the [Kubelet Stats Receiver](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/kubeletstatsreceiver#kubelet-stats-receiver) and the [Kubernetes Cluster Receiver](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/k8sclusterreceiver) and outputs metrics compatible with the Elastic Kubernetes integration. If you configure your collector to use this processor, you can see your pod metrics in the infrastructure inventory UI.

This repository has a minimal Terraform configuration to provision OpenTelemetry collectors in Kubernetes that collect pod and node metrics, use the infra metrics processor, and export to an Elasticsearch instance.

## How it works

The [Kubernetes pod view](https://www.elastic.co/docs/reference/observability/observability-kubernetes-pod-metrics) in the inventory is defined against the Kubernetes integration's schema. It filters documents on `event.module: kubernetes`, identifies a pod by `kubernetes.pod.uid`, labels it with `kubernetes.pod.name`, and charts these four metrics:

| Inventory column | Field | Aggregation |
|---|---|---|
| CPU Usage | `kubernetes.pod.cpu.usage.node.pct` | average |
| Memory Usage | `kubernetes.pod.memory.usage.node.pct` | average |
| Inbound Traffic | `kubernetes.pod.network.rx.bytes` | rate of the max |
| Outbound Traffic | `kubernetes.pod.network.tx.bytes` | rate of the max |

An OpenTelemetry collector produces none of those fields natively. The kubelet stats receiver emits `k8s.pod.*` metrics with OTel semantic convention names, and by default the Elasticsearch exporter writes them as-is. The pipelines below turn one into the other. Two collectors run, one per node for kubelet metrics and one per cluster for API server metrics, and each has its own copy of the same processing chain:

```
DaemonSet, one per node              Deployment, one per cluster
kubelet_stats                        k8s_cluster
  -> k8s_attributes                    -> resource/drop_collector_identity
                                       -> transform/allocatable_cpu_int
  -> resource_detection/env, resource/hostname
  -> elasticinframetrics        k8s.* -> kubernetes.*, drop originals
  -> attributes                 event.module = kubernetes (+ dataset for node metrics)
  -> transform/ecs_mapping_mode scope attribute elastic.mapping.mode = ecs
  -> batch/metrics              one scrape per bulk request
  -> elasticsearch              -> metrics-kubernetes.pod-default
                                -> metrics-kubernetes.state_node-default
```

Stage by stage:

1. **Kubelet stats receiver.** Runs in a DaemonSet so each collector scrapes its own node's kubelet at `<node>:10250/stats/summary` using the pod's service account token. Every metric it emits carries `k8s.pod.uid`, `k8s.pod.name`, `k8s.namespace.name` and `k8s.node.name` as resource attributes, and carries the receiver's Go module path as its instrumentation scope name. The four pod utilization metrics the processor needs (`k8s.pod.cpu.node.utilization`, `k8s.pod.memory.node.utilization`, `k8s.pod.cpu_limit_utilization`, `k8s.pod.memory_limit_utilization`) are disabled by default in the receiver and must be enabled explicitly. `k8s.pod.network.io` is on by default.

2. **Kubernetes cluster receiver.** Runs once per cluster as a single-replica Deployment and lists nodes, pods and workloads from the API server. It is the OpenTelemetry counterpart of kube-state-metrics. Of everything it emits, this example uses `k8s.node.allocatable_cpu` and `k8s.node.allocatable_memory`, which carry `k8s.node.name` and `k8s.node.uid` as resource attributes. Configuring this receiver makes the chart add the API permissions it needs to the ClusterRole.

3. **Kubernetes attributes processor** (DaemonSet only). Looks up each pod in the API server and adds workload metadata such as `k8s.deployment.name` and `k8s.daemonset.name`. Filtering on the collector's own node keeps each DaemonSet pod's watch small. These become `kubernetes.deployment.name` and so on in the ECS documents. This is enrichment, not required by the inventory.

4. **Collector identity** (Deployment only). The chart passes the collector pod's own name, namespace and IPs in `OTEL_RESOURCE_ATTRIBUTES`, and the env resource detector adds them to any resource that lacks them. Pod metrics already have their own values, but node metrics do not, so without this step every node document would name the collector pod. A resource processor deletes those attributes. `k8s.cluster.name` is kept.

5. **Allocatable CPU as an integer** (Deployment only). `k8s.node.allocatable_cpu` is a double, for example 3.92 cores. The infra metrics processor reads the data point as an integer and would produce 0 ([opentelemetry-lib#308](https://github.com/elastic/opentelemetry-lib/issues/308)), so a transform converts the value first. Fractional cores are truncated.

6. **Elastic infra metrics processor.** Only acts on scope metrics whose scope name starts with the kubeletstats receiver's or the k8s_cluster receiver's module path. Anything else passes through untouched. It reads these inputs and emits these outputs, tagging each data point with `data_stream.dataset` and `event.dataset`:

   | Source | Input (OTel) | Output (Kubernetes integration) | Dataset set by processor |
   |---|---|---|---|
   | kubelet | `k8s.pod.cpu.node.utilization` | `kubernetes.pod.cpu.usage.node.pct` | `kubernetes.pod` |
   | kubelet | `k8s.pod.memory.node.utilization` | `kubernetes.pod.memory.usage.node.pct` | `kubernetes.pod` |
   | kubelet | `k8s.pod.cpu_limit_utilization` | `kubernetes.pod.cpu.usage.limit.pct` | `kubernetes.pod` |
   | kubelet | `k8s.pod.memory_limit_utilization` | `kubernetes.pod.memory.usage.limit.pct` | `kubernetes.pod` |
   | kubelet | `k8s.pod.network.io` (direction=receive) | `kubernetes.pod.network.rx.bytes` | `kubernetes.pod` |
   | kubelet | `k8s.pod.network.io` (direction=transmit) | `kubernetes.pod.network.tx.bytes` | `kubernetes.pod` |
   | k8s_cluster | `k8s.node.allocatable_cpu` | `kubernetes.node.cpu.allocatable.cores` | `kubernetes.node` |
   | k8s_cluster | `k8s.node.allocatable_memory` | `kubernetes.node.memory.allocatable.bytes` | `kubernetes.node` |

   With `drop_original: true` the OTel originals in those scopes are removed, so the pipeline sends only ECS documents. Container and volume metrics from the kubelet, and the pod, deployment and other metrics from the cluster receiver, have no mapping in this processor and are dropped with the rest. `add_system_metrics: false` disables the host metrics remapper, which is not relevant here.

7. **Attributes.** The processor sets `event.dataset` but not `event.module`, and the inventory filters on `event.module: kubernetes`, so an attributes processor adds it. For node metrics the same processor also overrides the dataset to `kubernetes.state_node`. The processor labels them `kubernetes.node` ([opentelemetry-lib#307](https://github.com/elastic/opentelemetry-lib/issues/307)), but in the Kubernetes integration the two allocatable fields belong to the `state_node` dataset, the one fed by kube-state-metrics from the same API server data. See stage 9 for why this matters.

8. **Mapping mode.** The Elasticsearch exporter picks how to serialize each scope's metrics from the `elastic.mapping.mode` scope attribute. A transform processor sets it to `ecs`, which makes the exporter write flat ECS field names and route each document to `metrics-<data_stream.dataset>-<data_stream.namespace>`. That is `metrics-kubernetes.pod-default` and `metrics-kubernetes.state_node-default`.

9. **Index templates.** The Kubernetes integration, installed in Kibana, owns the `metrics-kubernetes.pod` and `metrics-kubernetes.state_node` index templates. Both create time series (TSDB) data streams with the integration's field mappings. Two properties of those templates shape this pipeline:

   - **Field mappings.** For any field the template does not map, the exporter's bulk request asks Elasticsearch to apply a dynamic template named `double_metrics`, which only exists in the OTel index templates. A document with an unmapped metric is rejected with `Can't find dynamic template for dynamic template name [double_metrics]`. The `kubernetes.node` template does not map the allocatable fields and `state_node` does, which is why node metrics are routed there.
   - **Dimensions.** A time series data stream identifies a series by its dimension fields and rejects documents that have none. `kubernetes.pod` uses `kubernetes.pod.uid` and `state_node` uses `kubernetes.node.name`, both of which these documents carry. `kubernetes.node` uses only `agent.id`, `service.address` and `orchestrator.cluster.url`, which Metricbeat sets and an OpenTelemetry collector does not.

   TSDB also drives one batch setting: `send_batch_max_size: 0` keeps a scrape in a single bulk request, since splitting it can raise `version_conflict_engine_exception` on time series indices.

Resulting documents, as stored by this example on minikube. A pod document:

```json
{
  "@timestamp": "2026-09-18T03:46:21.628Z",
  "data_stream": { "type": "metrics", "dataset": "kubernetes.pod", "namespace": "default" },
  "event": { "module": "kubernetes", "dataset": "kubernetes.pod", "ingested": "2026-09-18T03:46:31Z" },
  "kubernetes": {
    "namespace": "kube-system",
    "node": { "name": "minikube" },
    "deployment": { "name": "coredns" },
    "replicaset": { "name": "coredns-559f6c778d" },
    "pod": {
      "uid": "e3b51770-5bc7-4b97-8960-4bb2648968d9",
      "name": "coredns-559f6c778d-4rhzx",
      "cpu":     { "usage": { "node": { "pct": 0.0 },   "limit": { "pct": 0.0 } } },
      "memory":  { "usage": { "node": { "pct": 0.005 }, "limit": { "pct": 0.441 } } },
      "network": { "rx": { "bytes": 525118 }, "tx": { "bytes": 347977 } }
    }
  },
  "orchestrator": { "cluster": { "name": "minikube" } },
  "host": { "name": "minikube", "hostname": "minikube" },
  "service": { "type": "kubernetes" },
  "otel_remapped": true
}
```

A node document:

```json
{
  "@timestamp": "2026-09-18T06:12:59.703Z",
  "data_stream": { "type": "metrics", "dataset": "kubernetes.state_node", "namespace": "default" },
  "event": { "module": "kubernetes", "dataset": "kubernetes.state_node", "ingested": "2026-09-18T06:13:10Z" },
  "kubernetes": {
    "node": {
      "name": "minikube",
      "cpu":    { "allocatable": { "cores": 18.0 } },
      "memory": { "allocatable": { "bytes": 16743587840 } }
    }
  },
  "k8s": { "node": { "uid": "d655311c-aaf3-49ab-a29a-5fad9967457d" } },
  "orchestrator": { "cluster": { "name": "minikube" } },
  "host": { "name": "minikube", "hostname": "minikube" },
  "otel_remapped": true
}
```

The `kubernetes.*` fields are what the inventory and the Kubernetes integration dashboards read.

## What gets deployed

Terraform installs the [opentelemetry-kube-stack Helm chart](https://github.com/open-telemetry/opentelemetry-helm-charts/tree/main/charts/opentelemetry-kube-stack), the same chart and version the [Elastic Kubernetes quickstart](https://www.elastic.co/docs/solutions/observability/get-started/opentelemetry/quickstart/self-managed/k8s) uses, with a values file cut down from the [Elastic-recommended values](https://github.com/elastic/elastic-agent/blob/v9.5.4/deploy/helm/edot-collector/kube-stack/values.yaml). It creates:

- the `opentelemetry-operator-system` namespace and an `elastic-secret-otel` secret holding the Elasticsearch endpoint and API key, with the same names the Elastic quickstart uses
- the OpenTelemetry Operator, which turns `OpenTelemetryCollector` resources into workloads
- an `OpenTelemetryCollector` in DaemonSet mode running the Elastic Agent image, for kubelet pod metrics
- an `OpenTelemetryCollector` in Deployment mode with one replica, for API server node metrics

Compared with the recommended setup there are no logs, traces, host metrics, Kubernetes events, gateway collector or auto-instrumentation. The full configuration is in [values.yaml](./values.yaml), which is plain Helm values and can also be used with `helm install` directly. Terraform only layers three things on top: `clusterName`, the image tag and the exporters' TLS verification setting. See [main.tf](./main.tf).

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) 1.5 or later
- A Kubernetes cluster and a kubeconfig context pointing at it. The example was written against [minikube](https://minikube.sigs.k8s.io/), but any cluster works.
- Elasticsearch and Kibana 9.3 or later. The Elasticsearch endpoint must be reachable from pods inside the cluster.
- The Kubernetes integration installed in Kibana (**Integrations > Kubernetes > Install Kubernetes assets**). This installs the `metrics-kubernetes.pod` and `metrics-kubernetes.state_node` index templates. No agent policy is needed.
- An Elasticsearch API key

`kubectl` is useful for checking on the deployment but is not required. The Helm CLI is not required, the Terraform Helm provider talks to the cluster directly.

## Running the example

### 1. Start a cluster

```
minikube start
```

### 2. Create an API key

The collectors need `monitor` on the cluster, for the exporter's version check, and `auto_configure` plus `create_doc` on the metrics data streams. Create the key in Kibana under **Stack Management > API keys** with these role descriptors, or with the Elasticsearch API:

```
curl -k -u elastic_serverless:changeme -X POST https://localhost:9200/_security/api_key \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "edot-inframetrics",
    "role_descriptors": {
      "edot_metrics_writer": {
        "cluster": ["monitor"],
        "indices": [
          { "names": ["metrics-*-*"], "privileges": ["auto_configure", "create_doc"] }
        ]
      }
    }
  }'
```

Use the `encoded` value from the response.

### 3. Configure

Copy [terraform.tfvars.example](./terraform.tfvars.example) to `terraform.tfvars` and set the Elasticsearch endpoint. For an Elasticsearch running in Docker on the same machine as minikube, use `host.minikube.internal`, which minikube resolves to the host from inside the cluster:

```hcl
elasticsearch_endpoint             = "https://host.minikube.internal:9200"
elasticsearch_insecure_skip_verify = true # self-signed certificate
```

Rather than putting the API key in a file, you can pass it as an environment variable:

```
export TF_VAR_elasticsearch_api_key=<encoded API key>
```

See [variables.tf](./variables.tf) for all variables, including the Elastic Agent version, the chart version, the cluster name, and the kubeconfig context.

### 4. Apply

```
terraform init
terraform apply
```

The apply returns once the operator is ready. The operator then creates the collector DaemonSet and Deployment, which takes another minute or two for the image pull. Check on them with:

```
kubectl get pods -n opentelemetry-operator-system
kubectl logs -n opentelemetry-operator-system daemonset/opentelemetry-kube-stack-daemon-collector -f
kubectl logs -n opentelemetry-operator-system deployment/opentelemetry-kube-stack-cluster-stats-collector -f
```

The debug exporter is enabled at `basic` verbosity, so the logs show one line per batch sent. Elasticsearch exporter failures appear here as `bulk indexer flush error` for connection and authentication problems, or `failed to index document` for documents Elasticsearch rejected.

### 5. Verify the data

After the first 60 second collection interval, documents arrive in both data streams:

```
curl -k -u elastic_serverless:changeme 'https://localhost:9200/metrics-kubernetes.pod-default/_search?size=1&sort=@timestamp:desc&pretty'
curl -k -u elastic_serverless:changeme 'https://localhost:9200/metrics-kubernetes.state_node-default/_search?size=1&sort=@timestamp:desc&pretty'
```

In Kibana, Discover with the data view `metrics-*` and the query `event.module: kubernetes` shows the same documents. Then go to **Observability > Infrastructure > Inventory** and switch the view from **Hosts** to **Kubernetes Pods**. The pods running in the cluster appear, including the collectors themselves.

### Cleanup

```
terraform destroy
```

## Taking this to production

This example is deliberately the smallest thing that works. The points below are what changes when it becomes part of a full deployment.

- **Where the processor lives.** In the Elastic-recommended architecture the DaemonSet and Deployment collectors forward everything over OTLP to a gateway Deployment, and the gateway holds the Elasticsearch exporters. Put the `elasticinframetrics` chain in the gateway, and use a [routing connector](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/connector/routingconnector) on the instrumentation scope name to send only kubeletstats and k8s_cluster metrics through it while host metrics and application metrics keep the OTel mapping. [This branch of the Elastic Agent values file](https://github.com/elastic/elastic-agent/compare/9.4...smith:elastic-agent:otel-94-inframetrics) shows that layout for kubelet metrics: the daemon side is unchanged from upstream, and the gateway gains a `routing` connector, a `metrics/k8s/ecs` pipeline and an `elasticsearch/ecs` exporter. The per-source steps in this example, dropping the collector identity and converting the CPU value for cluster metrics, then need a routing condition of their own or must stay on the cluster collector.

- **Keep the OTel metrics too.** Set `drop_original: false` if you also want the native `k8s.*` metrics for the OpenTelemetry Kubernetes dashboards. In that case the ECS and OTel documents must go through different pipelines, because the mapping mode is set per scope, which is another reason to route by scope name.

- **Every ECS field must be mapped by the integration's template.** As stage 9 explains, an ECS document with a metric field the target template does not map is rejected. If a future version of the processor emits more fields, or you add your own, either send them to a dataset whose template maps them or add mappings through the integration's `@custom` component template, for example `metrics-kubernetes.state_node@custom`.

- **Deprecation.** Elastic marks `elasticinframetrics` as deprecated and keeps it in Elastic Agent 9.x for backwards compatibility. It is the only way to feed the pod inventory from an OpenTelemetry collector today.

- **Kubelet access.** The chart's ClusterRole grants the collector's service account the `nodes/stats` permission the kubelet API requires. The kubelet connection skips TLS verification because kubelet serving certificates are usually self-signed. `hostNetwork: true` is what lets the pod resolve the node name. Both are inherited from the Elastic values.

- **Network metrics.** `kubernetes.pod.network.rx.bytes` and `tx.bytes` come from the kubelet summary API, which does not report per-pod network stats on every runtime and CNI combination. Where it does not, the traffic columns in the inventory show `-` while CPU and memory are unaffected. On this minikube (Docker driver, containerd, kindnet) they were reported.

- **Scale.** Collection interval, `k8s_attributes` node filtering and the DaemonSet resource limits are the levers on the node side. The kubelet scrape is cheap and the API server watch is per node, so that scales linearly with node count. The cluster collector is a single pod that watches every object in the cluster and needs memory sized to the cluster's object count. The Elasticsearch exporter's `sending_queue` and retry settings are at their defaults here. Tune them and remove the `debug` exporter before running at volume.

- **Operator certificates.** The operator's admission webhooks use a self-signed certificate generated by the chart. Use cert-manager in production, as the upstream values recommend.

- **Running with Helm directly.** Create the namespace and secret as in the [Elastic quickstart](https://www.elastic.co/docs/solutions/observability/get-started/opentelemetry/quickstart/self-managed/k8s), uncomment the `tls` blocks in [values.yaml](./values.yaml) if needed, then:

  ```
  helm install opentelemetry-kube-stack open-telemetry/opentelemetry-kube-stack \
    --repo https://open-telemetry.github.io/opentelemetry-helm-charts \
    --namespace opentelemetry-operator-system \
    --values values.yaml \
    --version 0.16.0
  ```
