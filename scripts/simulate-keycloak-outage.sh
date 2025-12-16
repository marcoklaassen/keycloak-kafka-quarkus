#!/bin/bash

# Script to simulate Keycloak outage by patching the Keycloak route to point to a proxy
# that returns 500 errors. This avoids restarting the Quarkus pod.
# This helps reproduce customer issues where Quarkus experiences high CPU usage
# when Keycloak returns 500 errors.

set -e

NAMESPACE="${NAMESPACE:-qkk}"
KEYCLOAK_URL="${KEYCLOAK_URL:-https://keycloak-qkk.apps.ocp4.klaassen.click}"

echo "========================================="
echo "Keycloak Outage Simulation"
echo "========================================="
echo "This script will:"
echo "1. Deploy a proxy that returns 500 errors for Keycloak requests"
echo "2. Patch the Keycloak CR to change its hostname"
echo "3. Create a fake route with the original hostname pointing to the proxy"
echo "4. Quarkus continues using the same URL (no restart needed)"
echo ""
echo "Namespace: $NAMESPACE"
echo "Keycloak URL: $KEYCLOAK_URL"
echo ""

# Check if we're enabling or disabling the outage
ACTION="${1:-enable}"

if [ "$ACTION" == "enable" ]; then
    echo "Enabling Keycloak outage simulation..."
    
    # Extract hostname from KEYCLOAK_URL using bash parameter expansion
    # Remove protocol and path, keep only hostname
    ORIGINAL_HOSTNAME="${KEYCLOAK_URL#https://}"
    ORIGINAL_HOSTNAME="${ORIGINAL_HOSTNAME#http://}"
    ORIGINAL_HOSTNAME="${ORIGINAL_HOSTNAME%%/*}"
    # Prepend "original-" as a prefix to the hostname
    NEW_HOSTNAME="original-${ORIGINAL_HOSTNAME}"
    
    echo "Original hostname: $ORIGINAL_HOSTNAME"
    echo "New Keycloak hostname: $NEW_HOSTNAME"
    
    # Find the Keycloak custom resource
    KEYCLOAK_CR=$(kubectl get keycloak -n $NAMESPACE -o name | head -1)
    if [ -z "$KEYCLOAK_CR" ]; then
        echo "ERROR: Could not find Keycloak custom resource in namespace $NAMESPACE"
        echo "Available Keycloak resources:"
        kubectl get keycloak -n $NAMESPACE
        exit 1
    fi
    
    echo "Found Keycloak CR: $KEYCLOAK_CR"
    
    # Get the current hostname from the CR (this is the source of truth)
    CURRENT_HOSTNAME=$(kubectl get $KEYCLOAK_CR -n $NAMESPACE -o jsonpath='{.spec.hostname.hostname}' 2>/dev/null || echo "")
    
    # Use the hostname from CR if available, otherwise use extracted hostname
    if [ -n "$CURRENT_HOSTNAME" ] && [ "$CURRENT_HOSTNAME" != "null" ] && [[ ! "$CURRENT_HOSTNAME" =~ ^https?: ]]; then
        echo "Using hostname from CR: $CURRENT_HOSTNAME"
        ORIGINAL_HOSTNAME="$CURRENT_HOSTNAME"
    else
        echo "Using extracted hostname: $ORIGINAL_HOSTNAME"
    fi
    
    # Prepend "original-" as a prefix to the hostname
    NEW_HOSTNAME="original-${ORIGINAL_HOSTNAME}"
    
    # Save the original hostname for restoration
    echo "$ORIGINAL_HOSTNAME" > /tmp/keycloak-original-hostname.txt
    echo "Saved original hostname: $ORIGINAL_HOSTNAME"
    
    # Create ConfigMap with the proxy script
    echo "Creating proxy script ConfigMap..."
    kubectl create configmap keycloak-500-proxy-script -n $NAMESPACE \
        --from-file=proxy.py=chaos/keycloak-500-proxy.py \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Connect directly to Keycloak service (in-cluster, via HTTPS on port 8443)
    # This avoids SSL issues with the route's passthrough termination
    REAL_KEYCLOAK_URL="https://keycloak-service.${NAMESPACE}.svc.cluster.local:8443"
    
    # Deploy the proxy with the Keycloak service URL
    echo "Deploying 500 error proxy (reverse proxy to: $REAL_KEYCLOAK_URL)..."
    # Create a temporary YAML with the correct Keycloak URL
    cat chaos/keycloak-500-proxy.yaml | sed "s|value: \"https://keycloak-qkk.apps.ocp4.klaassen.click\"|value: \"$REAL_KEYCLOAK_URL\"|g" | kubectl apply -f -
    
    # Wait for proxy to be ready
    echo "Waiting for proxy to be ready..."
    kubectl wait --for=condition=available deployment/keycloak-500-proxy -n $NAMESPACE --timeout=60s || true
    
    # Patch the Keycloak CR to change the hostname
    # This will cause the operator to update the route to the new hostname
    echo "Patching Keycloak CR to change hostname to $NEW_HOSTNAME..."
    kubectl patch $KEYCLOAK_CR -n $NAMESPACE --type=json -p="[
        {
            \"op\": \"replace\",
            \"path\": \"/spec/hostname/hostname\",
            \"value\": \"$NEW_HOSTNAME\"
        }
    ]"
    
    # Wait a bit for the operator to update the route
    echo "Waiting for Keycloak operator to update the route..."
    sleep 5
    
    # Create a new route with the original hostname pointing to our proxy
    # Use the same TLS secret as Keycloak so Kafka trusts the certificate
    echo "Creating fake route with original hostname pointing to proxy..."
    
    # Extract certificate and key from the secret
    TLS_CERT=$(kubectl get secret keycloak-tls-secret -n $NAMESPACE -o jsonpath='{.data.tls\.crt}' | base64 -d)
    TLS_KEY=$(kubectl get secret keycloak-tls-secret -n $NAMESPACE -o jsonpath='{.data.tls\.key}' | base64 -d)
    
    # Create route YAML with embedded certificate
    cat > /tmp/keycloak-proxy-route.yaml <<ROUTE_EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: keycloak-500-proxy-route
  namespace: $NAMESPACE
spec:
  host: $ORIGINAL_HOSTNAME
  to:
    kind: Service
    name: keycloak-500-proxy
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
    certificate: |
$(echo "$TLS_CERT" | sed 's/^/      /')
    key: |
$(echo "$TLS_KEY" | sed 's/^/      /')
ROUTE_EOF
    kubectl apply -f /tmp/keycloak-proxy-route.yaml
    rm -f /tmp/keycloak-proxy-route.yaml
    
    # Update Kafka OAuth listener to accept tokens from the new issuer
    echo "Updating Kafka OAuth listener to accept new issuer..."
    NEW_ISSUER_URI="https://${NEW_HOSTNAME}/realms/kafka"
    NEW_JWKS_URI="https://${NEW_HOSTNAME}/realms/kafka/protocol/openid-connect/certs"
    
    # Patch the Kafka CR to update the issuer URIs
    kubectl patch kafka kafka -n $NAMESPACE --type=json -p="[
      {\"op\": \"replace\", \"path\": \"/spec/kafka/listeners/2/authentication/validIssuerUri\", \"value\": \"$NEW_ISSUER_URI\"},
      {\"op\": \"replace\", \"path\": \"/spec/kafka/listeners/2/authentication/jwksEndpointUri\", \"value\": \"$NEW_JWKS_URI\"}
    ]" || {
      echo "WARNING: Failed to patch Kafka CR. You may need to manually update the issuer URIs."
    }
    
    echo ""
    echo "========================================="
    echo "Keycloak outage simulation ENABLED"
    echo "========================================="
    echo "Keycloak CR hostname changed to: $NEW_HOSTNAME"
    echo "Fake route created with original hostname: $ORIGINAL_HOSTNAME -> proxy"
    echo "Quarkus will continue using the same URL ($KEYCLOAK_URL) but receive 500 errors"
    echo "No Quarkus pod restart required!"
    echo ""
    echo "Proxy configuration:"
    echo "  - /token/introspect endpoint: Returns 500 (matches customer scenario)"
    echo "  - Other endpoints: Forwarded to real Keycloak at $REAL_KEYCLOAK_URL"
    echo ""
    echo "To customize proxy behavior, edit the deployment:"
    echo "  kubectl set env deployment/keycloak-500-proxy -n $NAMESPACE FAIL_TOKEN_ENDPOINT=true  # Also fail /token"
    echo "  kubectl set env deployment/keycloak-500-proxy -n $NAMESPACE FAIL_ALL=true  # Fail all endpoints"
    echo ""
    echo "Monitor CPU usage with:"
    echo "  kubectl top pod -n $NAMESPACE -l app=quarkus-kafka-oauth"
    echo ""
    echo "Check Quarkus logs for authentication errors:"
    echo "  kubectl logs -n $NAMESPACE -l app=quarkus-kafka-oauth --tail=100 | grep -i 'authentication\\|token\\|introspect\\|credential\\|re-login'"
    echo ""
    echo "Check proxy logs to see which requests are failing:"
    echo "  kubectl logs -n $NAMESPACE -l app=keycloak-500-proxy --tail=50"
    echo ""
    echo "To disable the outage simulation, run:"
    echo "  $0 disable"
    
elif [ "$ACTION" == "disable" ]; then
    echo "Disabling Keycloak outage simulation..."
    
    # Extract hostname from KEYCLOAK_URL using bash parameter expansion
    # Remove protocol and path, keep only hostname
    ORIGINAL_HOSTNAME="${KEYCLOAK_URL#https://}"
    ORIGINAL_HOSTNAME="${ORIGINAL_HOSTNAME#http://}"
    ORIGINAL_HOSTNAME="${ORIGINAL_HOSTNAME%%/*}"
    
    # Find the Keycloak custom resource
    KEYCLOAK_CR=$(kubectl get keycloak -n $NAMESPACE -o name | head -1)
    if [ -z "$KEYCLOAK_CR" ]; then
        echo "ERROR: Could not find Keycloak custom resource in namespace $NAMESPACE"
        exit 1
    fi
    
    echo "Found Keycloak CR: $KEYCLOAK_CR"
    
    # Delete the fake route
    echo "Deleting fake proxy route..."
    kubectl delete route keycloak-500-proxy-route -n $NAMESPACE --ignore-not-found=true
    
    # Get the original hostname (prefer saved file, fallback to URL extraction)
    if [ -f /tmp/keycloak-original-hostname.txt ]; then
        SAVED_HOSTNAME=$(cat /tmp/keycloak-original-hostname.txt)
        if [ -n "$SAVED_HOSTNAME" ] && [[ ! "$SAVED_HOSTNAME" =~ ^https?: ]]; then
            ORIGINAL_HOSTNAME="$SAVED_HOSTNAME"
            echo "Restoring hostname from backup: $ORIGINAL_HOSTNAME"
        fi
    fi
    
    # Validate the hostname before restoring
    if [ -z "$ORIGINAL_HOSTNAME" ] || [[ "$ORIGINAL_HOSTNAME" =~ ^https?: ]] || [[ "$ORIGINAL_HOSTNAME" == original-* ]]; then
        echo "WARNING: Invalid hostname detected: $ORIGINAL_HOSTNAME"
        echo "Attempting to extract from current CR..."
        CURRENT_HOSTNAME=$(kubectl get $KEYCLOAK_CR -n $NAMESPACE -o jsonpath='{.spec.hostname.hostname}' 2>/dev/null || echo "")
        if [ -n "$CURRENT_HOSTNAME" ] && [[ "$CURRENT_HOSTNAME" == original-* ]]; then
            # Remove the original- prefix
            ORIGINAL_HOSTNAME="${CURRENT_HOSTNAME#original-}"
            echo "Extracted original hostname: $ORIGINAL_HOSTNAME"
        else
            echo "ERROR: Could not determine original hostname. Please restore manually."
            echo "Current CR hostname: $CURRENT_HOSTNAME"
            exit 1
        fi
    fi
    
    # Restore Kafka OAuth listener to use original issuer
    echo "Restoring Kafka OAuth listener to original issuer..."
    ORIGINAL_ISSUER_URI="https://${ORIGINAL_HOSTNAME}/realms/kafka"
    ORIGINAL_JWKS_URI="https://${ORIGINAL_HOSTNAME}/realms/kafka/protocol/openid-connect/certs"
    
    # Patch the Kafka CR to restore the original issuer URIs
    kubectl patch kafka kafka -n $NAMESPACE --type=json -p="[
      {\"op\": \"replace\", \"path\": \"/spec/kafka/listeners/2/authentication/validIssuerUri\", \"value\": \"$ORIGINAL_ISSUER_URI\"},
      {\"op\": \"replace\", \"path\": \"/spec/kafka/listeners/2/authentication/jwksEndpointUri\", \"value\": \"$ORIGINAL_JWKS_URI\"}
    ]" || {
      echo "WARNING: Failed to patch Kafka CR. You may need to manually restore the issuer URIs."
    }
    
    # Restore the original hostname using patch (more reliable than apply)
    echo "Restoring original Keycloak CR hostname to: $ORIGINAL_HOSTNAME"
    
    # Retry logic to handle conflicts
    MAX_RETRIES=3
    RETRY=0
    while [ $RETRY -lt $MAX_RETRIES ]; do
        if kubectl patch $KEYCLOAK_CR -n $NAMESPACE --type=json -p="[
            {
                \"op\": \"replace\",
                \"path\": \"/spec/hostname/hostname\",
                \"value\": \"$ORIGINAL_HOSTNAME\"
            }
        ]" 2>/dev/null; then
            echo "Successfully restored hostname"
            break
        else
            RETRY=$((RETRY + 1))
            if [ $RETRY -lt $MAX_RETRIES ]; then
                echo "Retry $RETRY/$MAX_RETRIES: Waiting before retry..."
                sleep 2
            else
                echo "ERROR: Failed to restore hostname after $MAX_RETRIES attempts"
                exit 1
            fi
        fi
    done
    
    # Clean up backup files
    rm -f /tmp/keycloak-cr-backup.yaml /tmp/keycloak-original-hostname.txt
    
    echo "Waiting for Keycloak operator to restore the route..."
    sleep 5
    
    # Optionally remove the proxy (comment out if you want to keep it)
    echo "Removing proxy deployment..."
    kubectl delete -f chaos/keycloak-500-proxy.yaml --ignore-not-found=true
    kubectl delete configmap keycloak-500-proxy-script -n $NAMESPACE --ignore-not-found=true
    
    echo ""
    echo "========================================="
    echo "Keycloak outage simulation DISABLED"
    echo "========================================="
    echo "Keycloak CR hostname restored to: $ORIGINAL_HOSTNAME"
    echo "Fake proxy route removed"
    echo "Quarkus will resume normal operation (no restart needed)"
    
else
    echo "Usage: $0 [enable|disable]"
    echo ""
    echo "  enable  - Deploy proxy, patch Keycloak CR, and create fake route (default)"
    echo "  disable - Restore Keycloak CR, remove fake route, and remove proxy"
    exit 1
fi

