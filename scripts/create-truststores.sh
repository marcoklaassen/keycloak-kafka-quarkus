#!/bin/bash

# Truststore Creation Script
# This script creates truststores for Keycloak and Kafka TLS certificates

set -e

NAMESPACE="${NAMESPACE:-qkk}"
KEYCLOAK_URL="${KEYCLOAK_URL:-keycloak-qkk.apps.ocp4.klaassen.click}"

echo "========================================="
echo "Truststore Creation Script"
echo "========================================="
echo ""

# Create temporary directory
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

echo "Step 1: Extracting Keycloak TLS certificate..."
# Get Keycloak certificate from secret
kubectl get secret keycloak-tls-secret -n $NAMESPACE -o jsonpath='{.data.tls\.crt}' | base64 -d > $TMP_DIR/keycloak.crt

if [ ! -s "$TMP_DIR/keycloak.crt" ]; then
    echo "ERROR: Failed to extract Keycloak certificate"
    exit 1
fi

echo "Step 2: Creating Keycloak truststore..."
KEYCLOAK_TRUSTSTORE_PASSWORD="${KEYCLOAK_TRUSTSTORE_PASSWORD:-changeit}"
keytool -import -noprompt -trustcacerts \
  -alias keycloak \
  -file $TMP_DIR/keycloak.crt \
  -keystore $TMP_DIR/keycloak-truststore.p12 \
  -storepass $KEYCLOAK_TRUSTSTORE_PASSWORD \
  -storetype PKCS12

echo "Step 3: Extracting Kafka TLS certificate..."
# Get Kafka cluster CA certificate
kubectl get secret kafka-cluster-ca-cert -n $NAMESPACE -o jsonpath='{.data.ca\.crt}' | base64 -d > $TMP_DIR/kafka-ca.crt

if [ ! -s "$TMP_DIR/kafka-ca.crt" ]; then
    echo "WARNING: Kafka CA certificate not found. You may need to create it manually."
    echo "Creating empty truststore..."
    keytool -genkeypair -noprompt \
      -alias kafka \
      -dname "CN=Kafka" \
      -keystore $TMP_DIR/kafka-truststore.p12 \
      -storepass changeit \
      -storetype PKCS12 \
      -keypass changeit
    keytool -delete -alias kafka \
      -keystore $TMP_DIR/kafka-truststore.p12 \
      -storepass changeit
else
    keytool -import -noprompt -trustcacerts \
      -alias kafka \
      -file $TMP_DIR/kafka-ca.crt \
      -keystore $TMP_DIR/kafka-truststore.p12 \
      -storepass changeit \
      -storetype PKCS12
fi

echo "Step 4: Creating Kubernetes secrets..."

# Create Keycloak truststore secret
kubectl create secret generic keycloak-truststore-secret \
  --from-file=truststore.p12=$TMP_DIR/keycloak-truststore.p12 \
  --from-literal=password="$KEYCLOAK_TRUSTSTORE_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -n $NAMESPACE -f -

# Create Kafka truststore secret
kubectl create secret generic kafka-truststore-secret \
  --from-file=truststore.p12=$TMP_DIR/kafka-truststore.p12 \
  --from-literal=password="changeit" \
  --dry-run=client -o yaml | kubectl apply -n $NAMESPACE -f -

echo ""
echo "========================================="
echo "Truststores created successfully!"
echo "========================================="
echo "Keycloak truststore secret: keycloak-truststore-secret"
echo "Kafka truststore secret: kafka-truststore-secret"
echo ""
echo "Note: Update deployment.yaml to mount these secrets"
echo "========================================="

