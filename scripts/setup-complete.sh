#!/bin/bash

# Complete Setup Script
# This script orchestrates the complete setup process

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "========================================="
echo "Complete Setup Script"
echo "========================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Step 1: Configure Keycloak
echo -e "${GREEN}Step 1: Configuring Keycloak...${NC}"
cd "$PROJECT_ROOT"
bash "$SCRIPT_DIR/configure-keycloak.sh"
if [ $? -ne 0 ]; then
    echo "ERROR: Keycloak configuration failed"
    exit 1
fi

# Get the client secret from the output
echo ""
echo -e "${YELLOW}Please enter the client secret from the Keycloak configuration:${NC}"
read -s KAFKA_CLIENT_SECRET
export KAFKA_CLIENT_SECRET

# Step 2: Update Kafka configuration (user needs to apply manually)
echo ""
echo -e "${GREEN}Step 2: Kafka OAuth Configuration${NC}"
echo "Please review and apply the updated Kafka configuration:"
echo "  kubectl apply -f $PROJECT_ROOT/kafka/02-kafka-instance-oauth.yaml"
echo ""
echo "Press Enter after applying the Kafka configuration..."
read

# Step 3: Create Kafka topics
echo ""
echo -e "${GREEN}Step 3: Creating Kafka topics...${NC}"
echo "Applying KafkaTopic custom resources..."
kubectl apply -f "$PROJECT_ROOT/kafka/07-kafka-topics.yaml"
if [ $? -ne 0 ]; then
    echo "ERROR: Topic creation failed"
    exit 1
fi
echo "Waiting for topics to be ready..."
sleep 10
kubectl get kafkatopics

# Step 4: Create secrets for Quarkus application
echo ""
echo -e "${GREEN}Step 4: Creating Kubernetes secrets...${NC}"
kubectl create secret generic kafka-oauth-secret \
  --from-literal=client-secret="$KAFKA_CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

# Step 5: Build Quarkus native image on OpenShift
echo ""
echo -e "${GREEN}Step 5: Building Quarkus native image on OpenShift...${NC}"
echo "This will create a BuildConfig and build a native executable."
echo "Note: Native builds can take 10-20 minutes..."
echo ""
bash "$SCRIPT_DIR/build-quarkus-openshift.sh"
if [ $? -ne 0 ]; then
    echo "ERROR: OpenShift build failed"
    exit 1
fi

# Step 6: Deploy application
echo ""
echo -e "${GREEN}Step 6: Deploying Quarkus application...${NC}"
kubectl apply -f "$PROJECT_ROOT/quarkus/deployment.yaml"

echo ""
echo "========================================="
echo "Setup Complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Verify Keycloak configuration at: https://keycloak-qkk.apps.ocp4.klaassen.click"
echo "2. Check Kafka topics are created"
echo "3. Monitor Quarkus application logs: kubectl logs -f deployment/quarkus-kafka-oauth"
echo "4. Test by sending a message to my-source-events topic"
echo ""

