#!/bin/bash

# Build Quarkus Native Image on OpenShift
# This script builds the Quarkus application as a native executable on OpenShift

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
QUARKUS_DIR="$PROJECT_ROOT/quarkus"
NAMESPACE="${NAMESPACE:-qkk}"

echo "========================================="
echo "OpenShift Native Build for Quarkus"
echo "========================================="
echo "Namespace: $NAMESPACE"
echo ""

# Check if oc is available
if ! command -v oc &> /dev/null; then
    echo "ERROR: oc (OpenShift CLI) is not installed or not in PATH"
    exit 1
fi

# Check if we're logged in
if ! oc whoami &> /dev/null; then
    echo "ERROR: Not logged in to OpenShift. Please run 'oc login' first."
    exit 1
fi

# Switch to the namespace
oc project $NAMESPACE

# Create ImageStream if it doesn't exist
echo "Creating ImageStream..."
oc apply -f "$QUARKUS_DIR/imagestream.yaml"

# Create BuildConfig (using binary build)
echo "Creating BuildConfig..."
oc apply -f "$QUARKUS_DIR/buildconfig.yaml"

# Start the build from local directory
echo ""
echo "Starting binary build from local directory..."
echo "This will upload the quarkus directory and build the native image."
echo "Note: Native builds can take 10-20 minutes..."
echo ""

cd "$QUARKUS_DIR"
oc start-build quarkus-kafka-oauth --from-dir=. --follow

if [ $? -eq 0 ]; then
    echo ""
    echo "========================================="
    echo "Build completed successfully!"
    echo "========================================="
    echo "Image: quarkus-kafka-oauth:latest"
    echo ""
    echo "You can now deploy the application:"
    echo "  kubectl apply -f $QUARKUS_DIR/deployment.yaml"
    echo ""
else
    echo ""
    echo "ERROR: Build failed. Check the build logs:"
    echo "  oc logs -f build/quarkus-kafka-oauth"
    exit 1
fi

