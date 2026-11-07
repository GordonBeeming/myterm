# Managed telemetry options for the relay

Research checked 7 November 2026 AEST against current official documentation. No service was provisioned, credentials accessed, or telemetry integration tested. Gordon subsequently selected Grafana Cloud for hosted live and beta. The initial plan is Free with 14-day history and email alerts; implementation settings remain to be validated.

## Scope and current decisions

The hosted relay needs managed, searchable logs, service metrics and alerts from its first deployment. Local-only logging does not meet that requirement. One hosted relay instance per environment is acceptable initially. Account deletion removes account-owned records; service-owned logs, request counts and performance history can remain. Gordon permits retained service logs to contain opaque reference IDs for accounts, servers, clients and other entities, including after deletion, to investigate repeated patterns and abuse.

The [earlier telemetry report](myterm-next-relay-telemetry.md) remains useful for its field allowlist and deletion research. Its recommendation to start with a local account-event store is not the hosted deployment direction being evaluated here. Its recommendation to make every account-linked diagnostic record follow account deletion is also not an agreed policy. An opaque ID remains account-linked even if policy eventually permits its retention.

## Current hosting scope

The comparison began while a Go/container relay was the candidate. Gordon subsequently selected Cloudflare's managed developer platform for both hosted and user-operated deployments. Users deploy into their own Cloudflare accounts; an independent container distribution is outside this release. Go ingestion details below describe evaluated options, not the selected release runtime.

The [deployment contract](../planning/myterm-next/relay-deployment-contract.md) owns the current collection design. Use sanitized application-only export by default. Cloudflare also documents native logs/traces export to Grafana; only enable it after automatic envelope fields and persistence pass the same privacy checks. Native export does not establish a metrics pipeline. No dedicated collector VM is required by this decision. [Workers export](https://developers.cloudflare.com/workers/observability/opentelemetry-export/).

## Comparison

| Option | Go collection and compatibility | Search and alerting | Main tradeoff for MyTerm |
| --- | --- | --- | --- |
| Azure Monitor / Application Insights | Go can emit standard OTLP through a collector. Microsoft's documented distro setup covers .NET, Java, Node.js and Python, without a Go distro. Native OTLP ingestion is currently Preview. | KQL in Log Analytics; Application Insights performance/failure investigation; metric and log-search alerts through action groups. | Familiar Azure operations and queries, but the production ingestion/support choice for Go needs explicit resolution. |
| Grafana Cloud | Native endpoint accepts OTLP logs, metrics and traces. Grafana recommends Alloy for production collection; another OpenTelemetry Collector can work with additional setup. | Loki/LogQL logs, Prometheus/Mimir metrics and Grafana Alerting. | Standard OTLP collection with LogQL/PromQL queries; requires careful label/cardinality budgets. |
| Better Stack | Official examples send all three signals through upstream OpenTelemetry Collector using OTLP HTTP or gRPC. | Live tail, SQL queries, dashboards, threshold/change/anomaly alerts and integrated incidents. | Credible managed alternative with SQL investigation; validate its metrics billing units and desired residency/permissions before choosing. |

Sources: [Microsoft distro language setup](https://learn.microsoft.com/en-us/azure/azure-monitor/app/opentelemetry-enable), [Azure OTLP preview](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/collect-use-observability-data), [Grafana OTLP collection](https://grafana.com/docs/grafana-cloud/send-data/otlp/send-data-otlp/), [Better Stack OTLP collection](https://betterstack.com/docs/logs/open-telemetry/). Search and alert details follow below.

OpenTelemetry Go currently marks traces and metrics stable and logs release candidate. Pin and validate the selected Go logging bridge/exporter versions, or evaluate structured application logs collected by an agent alongside stable Go metrics. Provider OTLP support does not make every language component equally mature. [Go component status](https://opentelemetry.io/docs/languages/go/).

### Azure Monitor / Application Insights

The native OTLP route supports an upstream contrib Collector outside AKS, authenticating through Microsoft Entra ID or managed identity. It requires HTTP/Protobuf export, delta metrics temporality and exponential histograms. Logs and traces support KQL investigation; metrics use the Prometheus store and Grafana experiences. Microsoft explicitly describes this route as Preview, without an SLA and not recommended for production. Live Metrics is unavailable on that route. This status applies to this collection path, not to Azure Monitor as a whole. [OTLP preview capabilities and limits](https://learn.microsoft.com/en-us/azure/azure-monitor/containers/collect-use-observability-data).

Two other ingestion paths deserve distinction. The upstream Collector's Azure Monitor exporter reports beta stability for traces, metrics and logs; that status is not a Microsoft production-support commitment. Azure's Logs Ingestion API accepts JSON through REST or client libraries and routes it using a data collection rule into supported/custom tables. That can provide searchable service logs from Go, but it does not by itself provide a complete OTLP metrics/APM integration. [Exporter source](https://raw.githubusercontent.com/open-telemetry/opentelemetry-collector-contrib/main/exporter/azuremonitorexporter/README.md), [Logs Ingestion API](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/logs-ingestion-api-overview).

Azure has metric alerts, scheduled log-search alerts and Prometheus alert rules. Action groups support email, SMS, push and webhooks. The chosen table plan matters: Analytics includes full KQL and alerting; the pricing page lists more limited capabilities and Preview simple log alerts for Basic. Avoid choosing the cheapest ingestion plan before checking the required alert/query behavior. [Alert types](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-overview), [table-plan pricing and capabilities](https://azure.microsoft.com/en-us/pricing/details/monitor/).

### Grafana Cloud

The managed endpoint accepts all three OTLP signals. Alloy adds transport handling, redaction, enrichment and routing; direct SDK export is the documented quickstart path or an option when a collector cannot be deployed. Go uses upstream instrumentation. This collector comparison preceded the Cloudflare hosting choice; the selected collection design is in the deployment contract. [OTLP architecture](https://grafana.com/docs/grafana-cloud/send-data/otlp/send-data-otlp/), [instrumentation options](https://grafana.com/docs/opentelemetry/instrument/).

LogQL supports log filtering, parsing and aggregation, while PromQL queries the metric store. Grafana Alerting evaluates queries and expressions against logs and metrics and routes notifications. This covers operational investigation and threshold alerts without MyTerm building a log-search UI. It still requires shipping queries, dashboards and alert rules with the deployment. [Query languages](https://grafana.com/docs/grafana-cloud/learn-and-build/telemetry-signals/query-visualize-data/visualize-query/learn-query-languages/), [Grafana Alerting](https://grafana.com/docs/grafana/latest/alerting/).

### Better Stack

Its upstream Collector guide supplies OTLP HTTP and gRPC configurations for logs, metrics and traces, with source-specific authentication. This gives Go a standard export path without depending on a vendor Go SDK. Its separate collector can add eBPF instrumentation, but automatic collection should not be enabled until its actual emitted fields pass MyTerm's allowlist. [OTLP guide](https://betterstack.com/docs/logs/open-telemetry/), [collector capabilities](https://betterstack.com/docs/logs/collector/).

Logs support SQL queries and live tail. Chart alerts support thresholds, percentage changes and anomaly detection, with confirmation/recovery windows and explicit missing-data behavior. Alerts create incidents; email is the default and other channels depend on configuration and plan. This is a credible option for SQL-based operations with incident management in the same service. [Log search](https://betterstack.com/docs/logs/logging-start/), [alerts](https://betterstack.com/docs/logs/dashboards/alerts/).

## Cost drivers and published allowances

These are product allowances, not a MyTerm estimate or proposed retention policy. Paid monetary rates are omitted; no currency conversion or regional quote was requested. Measure both environments together before comparing a paid bill, and confirm how each provider shares allowances across accounts, stacks and sources.

| Provider | Published free/included allowance | Paid usage drivers to size |
| --- | --- | --- |
| Azure Monitor | First 5 GB/month per billing account in the Analytics pay-as-you-go tier is free. Standard platform metrics/activity logs have separate no-cost treatment. This is not unlimited custom application telemetry. | Log ingestion/table plan, retention, export, metrics ingestion/querying, alert signals/frequency and notification channels. Regional rates need a selected region and offer. |
| Grafana Cloud | Free: 50 GB logs ingested/month and 10,000 active metric series, with 14-day retention. Pro includes those usage allowances and longer retention: 30 days logs, 13 months metrics. | Platform fee; log processing, writing and retention; metrics active series or DPM and excess query volume; optional product/incident features. |
| Better Stack | Published Logs & Traces allowance: 3 GB/month retained three days; Metrics lists 30 GB included. Free plan includes email/Slack alerts and ten monitors/heartbeats. | Logs/traces ingestion and retention; optional accelerated queries; metrics storage/retention; responder licences for phone/SMS; optional residency/security/archive features. |

Sources: [Azure pricing](https://azure.microsoft.com/en-us/pricing/details/monitor/), [Azure cost model](https://learn.microsoft.com/en-us/azure/azure-monitor/usage-estimated-costs), [Grafana pricing](https://grafana.com/pricing/), [Better Stack pricing](https://betterstack.com/pricing).

Grafana measures active series and DPM at the billing-period 95th percentile and bills whichever produces higher usage; query volume above an allowance also matters. A shorter scrape/export interval can increase cost even with the same metric names. Account IDs, connection IDs and arbitrary error strings must not become metric dimensions. Better Stack's GB allowance should not be treated as equivalent to Grafana's series allowance: obtain its exact measurement and retention calculation for the proposed metrics. [Grafana metrics billing](https://grafana.com/docs/grafana-cloud/platform/pricing-and-usage/metrics/).

## Redaction, enrichment and account correlation

Proposed collection contract: emit typed, allowlisted events; remove prohibited fields before they leave the relay or its local collector; apply a second filter at the managed boundary. OpenTelemetry documents attribute/filter/redaction/transform processors, but hashing identifiers does not establish anonymity. Provider ingestion transforms happen after data has reached the provider, so they cannot satisfy a requirement that prohibited values never leave the deployment. [OpenTelemetry sensitive-data guidance](https://opentelemetry.io/docs/security/handling-sensitive-data/).

Azure supports DCR transformations before destination-table ingestion. Better Stack supports VRL removal, filtering and enrichment before storage. These are useful extra controls, subject to pipeline-specific support, rather than permission to export arbitrary error strings or HTTP payloads. [Azure transformations](https://learn.microsoft.com/en-us/azure/azure-monitor/data-collection/data-collection-transformations), [Better Stack VRL](https://betterstack.com/docs/logs/using-logtail/transforming-ingested-data/logs-vrl/).

Use reviewed static service/environment/version attributes and finite event/outcome values. Do not enable automatic host, URL, query-string, header, baggage, database-query or network metadata collection by default. Application raw-IP collection is off initially under the deployment contract; enabling requires a verified separate restricted path. Any request/trace identifier and stack trace needs its own policy decision; vendor correlation features do not authorize collection.

Gordon permits entity reference IDs in retained service logs after deletion. Store them as searchable fields or structured metadata, with operator access control. Never make them Loki stream labels or metric dimensions: user/customer IDs are high-cardinality attributes. These records remain linkable operational data and follow service-log retention. [Loki cardinality](https://grafana.com/docs/loki/latest/get-started/labels/cardinality/), [OTLP field mapping](https://grafana.com/docs/loki/latest/send-data/otel/).

## User-operated diagnostics

A user-operated relay runs in the user's Cloudflare account and exports only to destinations the operator explicitly configures. Do not ship our Grafana destination or credentials as defaults. Application console output is retrievable only through an explicitly configured, privacy-verified diagnostic path. Do not promise retrievable logs when export, persistence and tailing are disabled. The implementation must document and verify the operator's chosen path, including provider-created system metadata, before enabling it.

Cloudflare's native destinations can send logs and traces to an operator's OTLP service. Confirm plan availability, emitted fields and metrics behavior during the implementation trial. Independent self-managed Loki/Prometheus/container examples are outside this release. [Workers export](https://developers.cloudflare.com/workers/observability/opentelemetry-export/).

## Provider decision and remaining questions

Gordon selected Grafana Cloud for hosted live and beta after reviewing the comparison and published Free/Pro pricing. Use reviewed OpenTelemetry export so operators deploying into their own Cloudflare accounts can choose their own destinations. No plan purchase, provisioning or deployment has occurred.

Implementation must validate the remaining operational details:

1. Entity reference IDs may remain after account deletion; validate that the exported stream excludes prohibited fields.
2. Start with Grafana Free and its 14-day history. Reassess plan and retention from measured usage and operational needs.
3. Select actual Grafana resources/regions and verify separate environment credentials, operator access and email notification delivery. No data-residency guarantee has been selected.
4. Define and validate sanitized Worker application export to Grafana, including envelope fields and redaction.
5. What are measured event bytes, series count, export interval and reconnect-burst volume? What limits apply to both environments combined?
6. Validate the agreed initial alerts and Gordon's email destination, with the concrete windows in the deployment contract. Distinguish abnormal sustained failures from normal rejected sign-ins.

No capacity benchmark, outage/retry test, deletion test, alert delivery test, paid quote or provider-support confirmation was performed. A bounded integration trial should establish those facts after the remaining configuration decisions.
