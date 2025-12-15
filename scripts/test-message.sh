#!/bin/bash

# Test Message Script
# This script sends a test message to the source topic and consumes from the target topic

set -e

KAFKA_BOOTSTRAP="${KAFKA_BOOTSTRAP:-kafka-kafka-bootstrap:9094}"
SOURCE_TOPIC="${SOURCE_TOPIC:-my-source-events}"
TARGET_TOPIC="${TARGET_TOPIC:-my-target-events}"
CLIENT_ID="${CLIENT_ID:-quarkus-kafka-client}"
NAMESPACE="${NAMESPACE:-qkk}"

echo "========================================="
echo "Test Message Script"
echo "========================================="
echo "Kafka Bootstrap: $KAFKA_BOOTSTRAP"
echo "Source Topic: $SOURCE_TOPIC"
echo "Target Topic: $TARGET_TOPIC"
echo ""

# Check if client secret is provided
if [ -z "$KAFKA_CLIENT_SECRET" ]; then
    echo "ERROR: KAFKA_CLIENT_SECRET environment variable is not set"
    echo "Please set it: export KAFKA_CLIENT_SECRET=\"<your-secret>\""
    exit 1
fi

KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak-qkk.apps.ocp4.klaassen.click}"
REALM_NAME="${REALM_NAME:-kafka}"
TOKEN_ENDPOINT="${KEYCLOAK_URL}/realms/${REALM_NAME}/protocol/openid-connect/token"

# Create a test message
TEST_MESSAGE='{"id":"test-001","message":"Hello from test script","timestamp":'$(date +%s)'}'

echo "Sending test message to $SOURCE_TOPIC:"
echo "$TEST_MESSAGE"
echo ""

# Get truststore passwords from secrets
OAUTH_TRUSTSTORE_PASSWORD=$(kubectl get secret keycloak-truststore-secret -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "changeit")
KAFKA_TRUSTSTORE_PASSWORD=$(kubectl get secret kafka-truststore-secret -n $NAMESPACE -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo "changeit")

# Send message using Kafka console producer with truststores
echo "Sending message..."
# Remove any existing producer pod and configmap first
kubectl delete pod kafka-test-producer -n $NAMESPACE --ignore-not-found=true 2>/dev/null
kubectl delete configmap kafka-test-producer-script -n $NAMESPACE --ignore-not-found=true 2>/dev/null
sleep 1

# Create a script that will be executed in the pod
# Use a quoted heredoc to prevent variable expansion, then use environment variable
cat > /tmp/producer-script.sh <<'SCRIPT_EOF'
#!/bin/sh
set -x
echo "Starting producer..."
echo "Message to send: $TEST_MESSAGE"
# Use printf with the environment variable to preserve exact formatting
printf '%s\n' "$TEST_MESSAGE" | bin/kafka-console-producer.sh \
  --bootstrap-server "$KAFKA_BOOTSTRAP" \
  --topic "$SOURCE_TOPIC" \
  --producer-property security.protocol=SASL_SSL \
  --producer-property sasl.mechanism=OAUTHBEARER \
  --producer-property sasl.login.callback.handler.class=io.strimzi.kafka.oauth.client.JaasClientOauthLoginCallbackHandler \
  --producer-property "sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required oauth.client.id=\"$CLIENT_ID\" oauth.client.secret=\"$KAFKA_CLIENT_SECRET\" oauth.scope=\"openid\" oauth.token.endpoint.uri=\"$TOKEN_ENDPOINT\" oauth.ssl.truststore.location=\"/etc/truststore/truststore.p12\" oauth.ssl.truststore.password=\"$OAUTH_TRUSTSTORE_PASSWORD\" oauth.ssl.truststore.type=\"PKCS12\" oauth.ssl.endpoint.identification.algorithm=\"\";" \
  --producer-property ssl.truststore.location=/etc/kafka-truststore/truststore.p12 \
  --producer-property ssl.truststore.password="$KAFKA_TRUSTSTORE_PASSWORD" \
  --producer-property ssl.truststore.type=PKCS12 \
  --producer-property value.serializer=org.apache.kafka.common.serialization.StringSerializer
PRODUCER_EXIT=$?
echo "Producer exit code: $PRODUCER_EXIT"
exit $PRODUCER_EXIT
SCRIPT_EOF

# Create ConfigMap from the script
kubectl create configmap kafka-test-producer-script -n $NAMESPACE --from-file=producer.sh=/tmp/producer-script.sh
rm -f /tmp/producer-script.sh

# Create the pod with the script mounted using kubectl create with --from-literal for env vars
# This avoids YAML escaping issues with complex JSON values
kubectl create -n $NAMESPACE -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kafka-test-producer
  namespace: $NAMESPACE
spec:
  containers:
  - name: kafka-test-producer
    image: quay.io/strimzi/kafka:latest-kafka-4.0.0
    command: ["/bin/sh", "/scripts/producer.sh"]
    env:
    - name: KAFKA_CLIENT_SECRET
      value: "$KAFKA_CLIENT_SECRET"
    - name: OAUTH_TRUSTSTORE_PASSWORD
      value: "$OAUTH_TRUSTSTORE_PASSWORD"
    - name: KAFKA_TRUSTSTORE_PASSWORD
      value: "$KAFKA_TRUSTSTORE_PASSWORD"
    - name: KAFKA_BOOTSTRAP
      value: "$KAFKA_BOOTSTRAP"
    - name: SOURCE_TOPIC
      value: "$SOURCE_TOPIC"
    - name: CLIENT_ID
      value: "$CLIENT_ID"
    - name: TOKEN_ENDPOINT
      value: "$TOKEN_ENDPOINT"
    - name: TEST_MESSAGE
      value: '$TEST_MESSAGE'
    volumeMounts:
    - name: oauth-truststore
      mountPath: /etc/truststore
      readOnly: true
    - name: kafka-truststore
      mountPath: /etc/kafka-truststore
      readOnly: true
    - name: producer-script
      mountPath: /scripts
      readOnly: true
  volumes:
  - name: oauth-truststore
    secret:
      secretName: keycloak-truststore-secret
  - name: kafka-truststore
    secret:
      secretName: kafka-truststore-secret
  - name: producer-script
    configMap:
      name: kafka-test-producer-script
      defaultMode: 0755
  restartPolicy: Never
EOF

# Wait for pod to start
echo "Waiting for producer pod to start..."
sleep 5

# Wait for pod to complete (with timeout)
echo "Waiting for producer to finish (max 30 seconds)..."
for i in {1..30}; do
    POD_STATUS=$(kubectl get pod kafka-test-producer -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$POD_STATUS" == "Succeeded" ] || [ "$POD_STATUS" == "Failed" ]; then
        break
    fi
    sleep 1
done

# Show logs
echo ""
echo "========================================="
echo "Producer pod logs:"
echo "========================================="
kubectl logs kafka-test-producer -n $NAMESPACE 2>&1 || echo "Pod not found or no logs available"

# Check pod status
POD_STATUS=$(kubectl get pod kafka-test-producer -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null)
echo ""
echo "Producer pod status: $POD_STATUS"
if [ "$POD_STATUS" == "Failed" ]; then
    echo ""
    echo "Pod failed. Checking events and container status:"
    kubectl describe pod kafka-test-producer -n $NAMESPACE | grep -A 15 "Events:" || true
    kubectl get pod kafka-test-producer -n $NAMESPACE -o jsonpath='{.status.containerStatuses[0].state}' | jq . 2>/dev/null || kubectl get pod kafka-test-producer -n $NAMESPACE -o jsonpath='{.status.containerStatuses[0].state}'
fi

echo ""
echo "To view full producer logs, run:"
echo "  kubectl logs kafka-test-producer -n $NAMESPACE"
echo "To delete the producer pod when done:"
echo "  kubectl delete pod kafka-test-producer -n $NAMESPACE"

echo ""
echo "Message sent! Waiting 5 seconds for processing..."
sleep 5

echo ""
echo "Consuming from $TARGET_TOPIC (timeout: 30 seconds):"
echo ""

# Consume message from target topic with truststores
echo "Consuming message..."
# Remove any existing consumer pod and configmap first
kubectl delete pod kafka-test-consumer -n $NAMESPACE --ignore-not-found=true 2>/dev/null
kubectl delete configmap kafka-test-consumer-script -n $NAMESPACE --ignore-not-found=true 2>/dev/null
sleep 1

# Create a script that will be executed in the pod
cat > /tmp/consumer-script.sh <<EOF
#!/bin/sh
set -x
echo "Starting consumer..."
timeout 30 bin/kafka-console-consumer.sh \
  --bootstrap-server $KAFKA_BOOTSTRAP \
  --topic $TARGET_TOPIC \
  --from-beginning \
  --max-messages 1 \
  --consumer-property security.protocol=SASL_SSL \
  --consumer-property sasl.mechanism=OAUTHBEARER \
  --consumer-property sasl.login.callback.handler.class=io.strimzi.kafka.oauth.client.JaasClientOauthLoginCallbackHandler \
  --consumer-property "sasl.jaas.config=org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required oauth.client.id=\"$CLIENT_ID\" oauth.client.secret=\"\$KAFKA_CLIENT_SECRET\" oauth.scope=\"openid\" oauth.token.endpoint.uri=\"$TOKEN_ENDPOINT\" oauth.ssl.truststore.location=\"/etc/truststore/truststore.p12\" oauth.ssl.truststore.password=\"\$OAUTH_TRUSTSTORE_PASSWORD\" oauth.ssl.truststore.type=\"PKCS12\" oauth.ssl.endpoint.identification.algorithm=\"\";" \
  --consumer-property ssl.truststore.location=/etc/kafka-truststore/truststore.p12 \
  --consumer-property ssl.truststore.password=\$KAFKA_TRUSTSTORE_PASSWORD \
  --consumer-property ssl.truststore.type=PKCS12
CONSUMER_EXIT=\$?
if [ \$CONSUMER_EXIT -ne 0 ]; then
    echo "Consumer exit code: \$CONSUMER_EXIT"
    echo "No messages found or timeout reached"
fi
exit \$CONSUMER_EXIT
EOF

# Create ConfigMap from the script
kubectl create configmap kafka-test-consumer-script -n $NAMESPACE --from-file=consumer.sh=/tmp/consumer-script.sh
rm -f /tmp/consumer-script.sh

# Create the pod with the script mounted using kubectl create
kubectl create -n $NAMESPACE -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kafka-test-consumer
  namespace: $NAMESPACE
spec:
  containers:
  - name: kafka-test-consumer
    image: quay.io/strimzi/kafka:latest-kafka-4.0.0
    command: ["/bin/sh", "/scripts/consumer.sh"]
    env:
    - name: KAFKA_CLIENT_SECRET
      value: "$KAFKA_CLIENT_SECRET"
    - name: OAUTH_TRUSTSTORE_PASSWORD
      value: "$OAUTH_TRUSTSTORE_PASSWORD"
    - name: KAFKA_TRUSTSTORE_PASSWORD
      value: "$KAFKA_TRUSTSTORE_PASSWORD"
    - name: KAFKA_BOOTSTRAP
      value: "$KAFKA_BOOTSTRAP"
    - name: TARGET_TOPIC
      value: "$TARGET_TOPIC"
    - name: CLIENT_ID
      value: "$CLIENT_ID"
    - name: TOKEN_ENDPOINT
      value: "$TOKEN_ENDPOINT"
    volumeMounts:
    - name: oauth-truststore
      mountPath: /etc/truststore
      readOnly: true
    - name: kafka-truststore
      mountPath: /etc/kafka-truststore
      readOnly: true
    - name: consumer-script
      mountPath: /scripts
      readOnly: true
  volumes:
  - name: oauth-truststore
    secret:
      secretName: keycloak-truststore-secret
  - name: kafka-truststore
    secret:
      secretName: kafka-truststore-secret
  - name: consumer-script
    configMap:
      name: kafka-test-consumer-script
      defaultMode: 0755
  restartPolicy: Never
EOF

# Wait for pod to start
echo "Waiting for consumer pod to start..."
sleep 5

# Wait for pod to complete (with timeout)
echo "Waiting for consumer to finish (max 35 seconds)..."
for i in {1..35}; do
    POD_STATUS=$(kubectl get pod kafka-test-consumer -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$POD_STATUS" == "Succeeded" ] || [ "$POD_STATUS" == "Failed" ]; then
        break
    fi
    sleep 1
done

# Show logs
echo ""
echo "========================================="
echo "Consumer pod logs:"
echo "========================================="
kubectl logs kafka-test-consumer -n $NAMESPACE 2>&1 || echo "Pod not found or no logs available"

# Check pod status
POD_STATUS=$(kubectl get pod kafka-test-consumer -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null)
echo ""
echo "Consumer pod status: $POD_STATUS"
if [ "$POD_STATUS" == "Failed" ]; then
    echo ""
    echo "Pod failed. Checking events and container status:"
    kubectl describe pod kafka-test-consumer -n $NAMESPACE | grep -A 15 "Events:" || true
    kubectl get pod kafka-test-consumer -n $NAMESPACE -o jsonpath='{.status.containerStatuses[0].state}' | jq . 2>/dev/null || kubectl get pod kafka-test-consumer -n $NAMESPACE -o jsonpath='{.status.containerStatuses[0].state}'
fi

echo ""
echo "To view full consumer logs, run:"
echo "  kubectl logs kafka-test-consumer -n $NAMESPACE"
echo "To delete the consumer pod when done:"
echo "  kubectl delete pod kafka-test-consumer -n $NAMESPACE"

echo ""
echo "========================================="
echo "Test completed!"
echo "========================================="

