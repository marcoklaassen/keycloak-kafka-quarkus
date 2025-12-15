#!/bin/bash

# Debug script to check what principal name Kafka sees
# This helps identify the correct principal name for superUsers configuration

set -e

KAFKA_BOOTSTRAP="${KAFKA_BOOTSTRAP:-kafka-kafka-bootstrap:9094}"
CLIENT_ID="${CLIENT_ID:-quarkus-kafka-client}"
NAMESPACE="${NAMESPACE:-qkk}"

echo "========================================="
echo "Kafka Principal Debug Script"
echo "========================================="
echo "Checking Kafka broker logs for principal names..."
echo ""

# Get Kafka broker pod
BROKER_POD=$(kubectl get pods -n $NAMESPACE -l strimzi.io/kind=Kafka,strimzi.io/name=kafka-kafka -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$BROKER_POD" ]; then
    echo "ERROR: Could not find Kafka broker pod"
    exit 1
fi

echo "Kafka broker pod: $BROKER_POD"
echo ""

# Search for principal-related log entries with more specific patterns
echo "Searching for principal names in logs..."
echo ""

# Look for OAuth principal extraction
echo "=== OAuth Principal Extraction ==="
kubectl logs -n $NAMESPACE $BROKER_POD --tail=500 | grep -i "principal\|oauth\|token" | grep -v "GrantsHandler" | tail -10 || echo "No OAuth principal entries found"
echo ""

# Look for authorization decisions (these show the actual principal being checked)
echo "=== Authorization Decisions ==="
kubectl logs -n $NAMESPACE $BROKER_POD --tail=500 | grep -i "authorization\|allow\|deny\|permission" | tail -10 || echo "No authorization decision entries found"
echo ""

# Look for grants endpoint calls (these show which user is being checked)
echo "=== Grants Endpoint Calls ==="
kubectl logs -n $NAMESPACE $BROKER_POD --tail=500 | grep -i "grant\|user:" | tail -10 || echo "No grants endpoint entries found"
echo ""

# Check for any errors that might show principal names
echo "=== Errors (may contain principal info) ==="
kubectl logs -n $NAMESPACE $BROKER_POD --tail=200 | grep -i "error\|exception\|failed" | grep -i "principal\|user\|client" | tail -10 || echo "No relevant errors found"
echo ""

echo "========================================="
echo "To trigger principal logging, try:"
echo "1. Send a test message: ./scripts/test-message.sh"
echo "2. Check Quarkus app logs: kubectl logs -n $NAMESPACE -l app=quarkus-kafka-oauth"
echo ""
echo "To see real-time logs, run:"
echo "kubectl logs -f -n $NAMESPACE $BROKER_POD | grep -iE 'principal|authorization|grant|user:'"
echo ""
echo "Common principal name formats to try in superUsers:"
echo "  - quarkus-kafka-client"
echo "  - User:quarkus-kafka-client"
echo "  - service-account-quarkus-kafka-client"
echo "========================================="

