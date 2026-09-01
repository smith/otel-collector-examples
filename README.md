# Elastic OpenTelemetry tail-based sampling example

This repository has a Docker Compose setup for running an Elastic Agent OpenTelemetry Collector based on the [Elastic documentation for configuring trace collection](https://www.elastic.co/docs/reference/edot-collector/config/configure-tracing-collection).

It can be used to run an otel collector with tail-based sampling enabled, so you can have sample data in Kibana that has been through tail-based sampling.

It's designed to run against a Kibana development instance, so the otel collector is set up to send to host.docker.internal:9200.

To run, have a `yarn es serverless` or local ES instance running in docker.

Create an API key, then run:

```
env ELASTICSEARCH_API_KEY=<YOUR API KEY> docker compose up -d
```

This will start the otel collector in docker with shared 4317/4318 ports. Any OTLP data sent there should end up in Elasticsearch. Traces will be tail-based sampled based on the settings in [otel-collector.yaml](./otel-collectory.yaml).

## Running the OpenTelemetry demo

Checkout the [OpenTelemetry repo](https://github.com/open-telemetry/opentelemetry-demo) and run:

```
env OTEL_COLLECTOR_HOST=host.docker.internal docker compose up -d
```

The otel demo data should now be in your Kibana instance with tail-based sampling enabled.
