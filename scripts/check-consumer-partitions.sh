#!/bin/bash
# Script to check which Quarkus pods have Kafka partitions assigned

set -e

NAMESPACE="${NAMESPACE:-qkk}"
CONSUMER_GROUP="${CONSUMER_GROUP:-quarkus-event-processor-group}"
KAFKA_BOOTSTRAP="${KAFKA_BOOTSTRAP:-kafka-kafka-bootstrap:9092}"

echo "Checking consumer group: $CONSUMER_GROUP"
echo "=========================================="
echo ""

# Find a Kafka broker pod
KAFKA_POD=$(kubectl get pods -n $NAMESPACE -o name | grep kafka-broker | head -1 | sed 's|pod/||')

if [ -z "$KAFKA_POD" ]; then
    echo "ERROR: Could not find Kafka broker pod"
    echo "Available pods:"
    kubectl get pods -n $NAMESPACE | grep kafka
    exit 1
fi

echo "Using Kafka pod: $KAFKA_POD"
echo ""

# Get consumer group description
echo "Consumer Group Members and Partition Assignments:"
echo "---------------------------------------------------"
# Try with OAuth listener first (port 9094), fallback to plain (9092)
kubectl exec -n $NAMESPACE $KAFKA_POD -- kafka-consumer-groups.sh \
    --bootstrap-server kafka-kafka-bootstrap.$NAMESPACE.svc:9094 \
    --command-config /tmp/strimzi-oauth.properties \
    --group $CONSUMER_GROUP \
    --describe 2>/dev/null || \
kubectl exec -n $NAMESPACE $KAFKA_POD -- kafka-consumer-groups.sh \
    --bootstrap-server localhost:9092 \
    --group $CONSUMER_GROUP \
    --describe 2>/dev/null || {
    echo "Note: Consumer group command may require authentication"
    echo "Checking via application logs instead..."
}

echo ""
echo "=========================================="
echo "Checking Quarkus pod logs for partition assignments..."
echo ""

# Check each Quarkus pod's logs for partition assignment info
echo "Checking individual pod partition assignments..."
echo ""

ACTIVE_PODS=0
INACTIVE_PODS=0

for pod in $(kubectl get pods -n $NAMESPACE -l app=quarkus-kafka-oauth -o name | sed 's|pod/||'); do
    # Look for partition assignment in logs
    # Check for "assigned partitions" or offset commit messages which indicate active partition ownership
    ASSIGNED=$(kubectl logs -n $NAMESPACE $pod --tail=200 2>/dev/null | grep -E "assigned partitions|OffsetAndMetadata|my-source-events-[0-9]+=OffsetAndMetadata" | tail -1)
    
    # Check for recent successful message processing (indicates active consumer)
    PROCESSING=$(kubectl logs -n $NAMESPACE $pod --tail=50 2>/dev/null | grep -E "Received event|Processed event" | tail -1)
    
    # Check for rebalancing/revoked messages (indicates consumer was active but got kicked out)
    REBALANCING=$(kubectl logs -n $NAMESPACE $pod --tail=100 2>/dev/null | grep -E "revoked|re-balance|kicked out" | tail -1)
    
    if [ -n "$ASSIGNED" ]; then
        echo "✓ $pod - HAS PARTITION ASSIGNED"
        echo "  $ASSIGNED" | sed 's/^/    /'
        if [ -n "$PROCESSING" ]; then
            echo "  Recent processing: $PROCESSING" | sed 's/^/    /'
        fi
        ACTIVE_PODS=$((ACTIVE_PODS + 1))
    elif [ -n "$REBALANCING" ]; then
        echo "⚠ $pod - WAS ASSIGNED BUT KICKED OUT"
        echo "  $REBALANCING" | sed 's/^/    /'
        INACTIVE_PODS=$((INACTIVE_PODS + 1))
    else
        echo "○ $pod - NO PARTITION (inactive consumer)"
        INACTIVE_PODS=$((INACTIVE_PODS + 1))
    fi
    echo ""
done

echo "=========================================="
echo "Summary:"
TOTAL_PODS=$(kubectl get pods -n $NAMESPACE -l app=quarkus-kafka-oauth --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "  Total Quarkus pods: $TOTAL_PODS"
echo "  Pods with partitions: $ACTIVE_PODS"
echo "  Pods without partitions: $INACTIVE_PODS"
echo "  Topic partitions: 3 (my-source-events)"
echo ""
if [ $ACTIVE_PODS -gt 3 ]; then
    echo "⚠ WARNING: More than 3 pods have partitions assigned (expected: 3)"
elif [ $ACTIVE_PODS -lt 3 ]; then
    echo "⚠ WARNING: Less than 3 pods have partitions assigned (expected: 3)"
fi
echo ""
echo "Note: Only 3 pods should have partitions assigned (one per partition)"
echo "Pods without partitions may still consume CPU due to:"
echo "  - Consumer group rebalancing attempts (constant rejoin attempts)"
echo "  - OAuth token refresh retries (especially during Keycloak outages)"
echo "  - Connection keep-alive attempts"
echo "  - Failed authentication retries"

