# Keycloak Outage Simulation

This directory contains tools to simulate Keycloak outages by returning 500 errors, which helps reproduce customer issues where Quarkus experiences high CPU usage when Keycloak is unavailable.

## Overview

When Keycloak returns 500 errors, the Kafka OAuth client in Quarkus may retry aggressively, causing:
- High CPU usage
- Increased network traffic
- Potential resource exhaustion

## Usage

### Enable Outage Simulation

```bash
./scripts/simulate-keycloak-outage.sh enable
```

This will:
1. Deploy a proxy service that returns 500 errors for all requests
2. Update the Quarkus deployment to use the proxy instead of Keycloak
3. The proxy will intercept all OAuth token requests and return 500 errors

### Monitor CPU Usage

While the outage is active, monitor the Quarkus pod CPU usage:

```bash
# Watch CPU usage
watch -n 2 'kubectl top pod -n qkk -l app=quarkus-kafka-oauth'

# Or check logs for retry attempts
kubectl logs -n qkk -l app=quarkus-kafka-oauth --tail=50 | grep -i "oauth\|token\|error\|retry"
```

### Disable Outage Simulation

```bash
./scripts/simulate-keycloak-outage.sh disable
```

This will:
1. Restore the original Keycloak URL in the Quarkus deployment
2. Remove the proxy deployment
3. Quarkus will resume normal operation

## How It Works

1. **Proxy Service**: A simple Python HTTP server that returns 500 errors for all requests
2. **Route**: An OpenShift Route exposes the proxy with TLS passthrough
3. **Environment Variable**: The Quarkus deployment's `KEYCLOAK_TOKEN_ENDPOINT` is updated to point to the proxy

## Customization

### Proxy Behavior

The proxy is configured to match the customer scenario:
- **`/token/introspect` endpoint**: Always returns 500 (matches customer logs)
- **Other endpoints**: Return 200 OK by default

### Environment Variables

You can customize the proxy behavior using environment variables:

```bash
# Also fail the /token endpoint (for getting new tokens)
kubectl set env deployment/keycloak-500-proxy -n qkk FAIL_TOKEN_ENDPOINT=true

# Fail all endpoints
kubectl set env deployment/keycloak-500-proxy -n qkk FAIL_ALL=true

# Restore default behavior (only fail /introspect)
kubectl set env deployment/keycloak-500-proxy -n qkk FAIL_TOKEN_ENDPOINT=false FAIL_ALL=false
```

### Error Response Format

The proxy returns the exact error format from customer logs:
```json
{"error":"unknown_error","error_description":"For more on this error consult the server log."}
```

This matches what the customer's Keycloak returns, which causes:
- Kafka authentication failures
- Token validation errors
- Credential expiration and re-login attempts
- High CPU usage from retry loops

### Monitoring the Scenario

Watch for these specific log patterns that match the customer issue:

**In Quarkus logs:**
- `Expiring credential` - Token expiration warnings
- `Initiating re-login` - Re-authentication attempts
- `authentication error occurred in the heartbeat thread` - Heartbeat failures
- `Failed re-authentication` - Re-auth failures
- `Runtime failure during token validation` - Token validation errors

**In Kafka broker logs:**
- `POST request to .../token/introspect failed with status 500` - Introspection failures
- `HttpException` - HTTP errors from Keycloak


**In Prometheus:**
```
sum(
  rate(
    container_cpu_usage_seconds_total{container!="", container!="POD"}[5m]
  )
* on(pod) group_left(label_app)
  kube_pod_labels{label_app="quarkus-kafka-oauth"}
) by (pod)
```

## Troubleshooting

### Proxy Not Working

Check if the proxy is running:
```bash
kubectl get pods -n qkk -l app=keycloak-500-proxy
kubectl logs -n qkk -l app=keycloak-500-proxy
```

### Quarkus Not Using Proxy

Verify the environment variable:
```bash
kubectl get deployment quarkus-kafka-oauth -n qkk -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KEYCLOAK_TOKEN_ENDPOINT")].value}'
```

### Route Not Accessible

Check the route:
```bash
kubectl get route keycloak-500-proxy -n qkk
```

## Alternative Approaches

1. **Network Policies**: Block traffic to Keycloak using NetworkPolicy
2. **Service Disruption**: Scale down Keycloak to 0 replicas
3. **Toxiproxy**: Use Toxiproxy for more advanced failure injection
4. **Istio Fault Injection**: If using Istio, use fault injection policies

