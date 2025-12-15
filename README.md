# Quarkus Kafka Keycloak Integration

This project demonstrates a Quarkus application that consumes messages from a Kafka topic, processes them, and produces to another topic, using OAuth Bearer authentication with Keycloak.

## Architecture

- **Keycloak**: OAuth/OIDC authentication provider
- **Kafka (Strimzi)**: Message broker with OAuth authentication
- **Quarkus Application**: Event processor consuming from `my-source-events` and producing to `my-target-events`

## Prerequisites

- OpenShift/Kubernetes cluster
- Keycloak instance deployed
- Kafka (Strimzi) instance deployed
- `kubectl` configured
- `curl` and `jq` installed
- OpenShift CLI (`oc`) configured and logged in

## Setup Instructions

### 1. Configure Keycloak

Run the Keycloak configuration script to create the realm and client:

```bash
cd scripts
export ADMIN_USER=<user>
export ADMIN_PASSWORD=<password>
./configure-keycloak.sh
```

This script will:
- Create a `kafka` realm in Keycloak
- Create a `quarkus-kafka-client` client with service account enabled
- Generate and display the client secret

**Important**: Save the client secret displayed at the end of the script output.

### 2. Update Kafka Configuration

Apply the OAuth-enabled Kafka configuration:

```bash
kubectl apply -f kafka/02-kafka-instance-oauth.yaml
```

This adds an OAuth listener on port 9094 and configures OAuth authorization.

### 3. Create Kafka Topics

Create the required topics using Strimzi KafkaTopic custom resources:

```bash
kubectl apply -f kafka/07-kafka-topics.yaml
```

This creates:
- `my-source-events` (source topic)
- `my-target-events` (target topic)

The topics are managed by the Strimzi Entity Operator. You can verify creation with:

```bash
kubectl get kafkatopics
```

### 4. Create Truststores

Create truststores for Keycloak and Kafka TLS certificates:

```bash
./scripts/create-truststores.sh
```

This creates Kubernetes secrets with the truststores needed for TLS connections.

### 5. Create Kubernetes Secrets

Create the secret for the Kafka client secret:

```bash
export KAFKA_CLIENT_SECRET="<client-secret-from-step-1>"
kubectl create secret generic kafka-oauth-secret \
  --from-literal=client-secret="$KAFKA_CLIENT_SECRET"
```

### 6. Build and Deploy Quarkus Application

Build the native Quarkus application on OpenShift:

```bash
./scripts/build-quarkus-openshift.sh
```

This script will:
- Create a BuildConfig for native image builds
- Upload the Quarkus source code to OpenShift
- Build a native executable image (this takes 10-20 minutes)
- Create an ImageStream with the built image

Alternatively, you can build manually:

```bash
# Create ImageStream
oc create imagestream quarkus-kafka-oauth

# Create BuildConfig
oc apply -f quarkus/buildconfig.yaml

# Start binary build
cd quarkus
oc start-build quarkus-kafka-oauth --from-dir=. --follow
```

**Important:** Wait for the build to complete successfully before deploying. The build creates the ImageStream with the image.

Deploy the application:

```bash
# First, ensure the ImageStream exists and has the image
oc apply -f quarkus/imagestream.yaml

# Then deploy the application
kubectl apply -f quarkus/deployment.yaml
```

The deployment references the image using the OpenShift internal registry path: `image-registry.openshift-image-registry.svc:5000/qkk/quarkus-kafka-oauth:latest`

**Note:** If you're using a different namespace than `qkk`, update the image path in `quarkus/deployment.yaml` to match your namespace. You can get the correct image path by running:
```bash
oc get imagestream quarkus-kafka-oauth -o jsonpath='{.status.dockerImageRepository}:latest'
```

If you get an error about pulling from Docker Hub, ensure:
1. The build has completed successfully
2. The ImageStream exists: `oc get imagestream quarkus-kafka-oauth`
3. The ImageStream has the image: `oc describe imagestream quarkus-kafka-oauth`
4. The namespace in the deployment image path matches your actual namespace

### 7. Verify Deployment

Check the application logs:

```bash
kubectl logs -f deployment/quarkus-kafka-oauth
```

### 8. Troubleshooting Authorization Issues

If you see `TOPIC_AUTHORIZATION_FAILED` errors in the Quarkus application logs, the client may not have the correct permissions. With Keycloak authorization, check:

1. **Verify superUsers configuration**: The Kafka configuration includes `quarkus-kafka-client` as a super user, which should grant all permissions. If this doesn't work, the principal name might not match.

2. **Check the actual principal name**: Run the debug script to see what principal name Kafka is seeing:
   ```bash
   ./scripts/debug-kafka-principal.sh
   ```

3. **Update superUsers if needed**: If the principal name is different, update `kafka/02-kafka-instance-oauth.yaml` to include the correct principal name in the `superUsers` list.

4. **Alternative: Use Keycloak roles**: Instead of superUsers, you can configure roles in Keycloak and grant permissions through the Keycloak authorization system. This requires additional configuration in both Keycloak and Kafka.

5. **"Default Resource" error**: If you see errors about "Default Resource" not following the `TYPE:NAME` pattern, Keycloak has created a default authorization resource that Strimzi doesn't support. The configuration script will automatically remove it, but if you see this error:
   - Re-run `./scripts/configure-keycloak.sh` to clean up the default resource
   - Or manually remove it from Keycloak admin console: Clients → `quarkus-kafka-client` → Authorization → Resources → Delete "Default Resource"

6. **"Invalid grants: not a JSON array" error**: If you see this error in Kafka broker logs (marked as `[IGNORED]`), it means the Keycloak grants endpoint is returning an error object instead of a JSON array. This is a known issue when using Keycloak authorization with `superUsers`. **This error can be safely ignored** because:
   - The error is marked as `[IGNORED]` in the logs, meaning Kafka handles it gracefully
   - Since Kafka is configured with `superUsers`, authorization is bypassed for those users anyway
   - Kafka still functions correctly despite this warning
   
   If you want to eliminate the warning (optional):
   - The configuration script attempts to create authorization resources and permissions, but Keycloak's UMA ticket endpoint may still return an error when there are no matching permissions
   - To fully resolve it, you would need to configure proper authorization resources and permissions in Keycloak that match your Kafka topics and operations
   - Alternatively, you can switch to `simple` authorization type if you don't need Keycloak-based authorization

## Configuration

### Environment Variables

The Quarkus application uses the following environment variables:

- `KAFKA_BOOTSTRAP_SERVERS`: Kafka bootstrap servers (default: `kafka-kafka-bootstrap:9094`)
- `KAFKA_CLIENT_SECRET`: OAuth client secret from Keycloak
- `KEYCLOAK_TOKEN_ENDPOINT`: Keycloak token endpoint URL
- `OAUTH_TRUSTSTORE_LOCATION`: Path to Keycloak TLS truststore
- `KAFKA_TRUSTSTORE_LOCATION`: Path to Kafka TLS truststore

### Application Properties

The main configuration is in `quarkus/src/main/resources/application.properties`:

- Consumer: `my-source-events` topic
- Producer: `my-target-events` topic
- Authentication: OAUTHBEARER with Keycloak

## Testing

### Send a Test Message

You can send a test message to the source topic using the Kafka console producer. **Note:** The OAuth truststore must be mounted to validate Keycloak's SSL certificate.

The easiest way is to use the provided test script:

```bash
export KAFKA_CLIENT_SECRET="<your-client-secret>"
./scripts/test-message.sh
```

Or manually with truststore configuration:

```bash
# Get truststore password
TRUSTSTORE_PASSWORD=$(kubectl get secret keycloak-truststore-secret -n qkk -o jsonpath='{.data.password}' | base64 -d)

# Send message with truststore mounted
kubectl run kafka-producer -n qkk \
  --image=quay.io/strimzi/kafka:latest-kafka-4.0.0 \
  --rm -i --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"kafka-producer","volumeMounts":[{"name":"oauth-truststore","mountPath":"/etc/truststore","readOnly":true}]}],"volumes":[{"name":"oauth-truststore","secret":{"secretName":"keycloak-truststore-secret"}}]}}' -- \
  bin/kafka-console-producer.sh \
  --bootstrap-server kafka-kafka-bootstrap:9094 \
  --topic my-source-events \
  --producer-property security.protocol=SASL_SSL \
  --producer-property sasl.mechanism=OAUTHBEARER \
  --producer-property sasl.login.callback.handler.class=io.strimzi.kafka.oauth.client.JaasClientOauthLoginCallbackHandler \
  --producer-property sasl.jaas.config="org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required oauth.client.id=\"quarkus-kafka-client\" oauth.client.secret=\"<your-secret>\" oauth.scope=\"openid\" oauth.token.endpoint.uri=\"https://keycloak-qkk.apps.ocp4.klaassen.click/realms/kafka/protocol/openid-connect/token\" oauth.ssl.truststore.location=\"/etc/truststore/truststore.p12\" oauth.ssl.truststore.password=\"$TRUSTSTORE_PASSWORD\" oauth.ssl.truststore.type=\"PKCS12\" oauth.ssl.endpoint.identification.algorithm=\"\";"
```

### Consume from Target Topic

```bash
# Get truststore password
TRUSTSTORE_PASSWORD=$(kubectl get secret keycloak-truststore-secret -n qkk -o jsonpath='{.data.password}' | base64 -d)

# Consume with truststore mounted
kubectl run kafka-consumer -n qkk \
  --image=quay.io/strimzi/kafka:latest-kafka-4.0.0 \
  --rm -i --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"kafka-consumer","volumeMounts":[{"name":"oauth-truststore","mountPath":"/etc/truststore","readOnly":true}]}],"volumes":[{"name":"oauth-truststore","secret":{"secretName":"keycloak-truststore-secret"}}]}}' -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server kafka-kafka-bootstrap:9094 \
  --topic my-target-events \
  --from-beginning \
  --consumer-property security.protocol=SASL_SSL \
  --consumer-property sasl.mechanism=OAUTHBEARER \
  --consumer-property sasl.login.callback.handler.class=io.strimzi.kafka.oauth.client.JaasClientOauthLoginCallbackHandler \
  --consumer-property sasl.jaas.config="org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required oauth.client.id=\"quarkus-kafka-client\" oauth.client.secret=\"<your-secret>\" oauth.scope=\"openid\" oauth.token.endpoint.uri=\"https://keycloak-qkk.apps.ocp4.klaassen.click/realms/kafka/protocol/openid-connect/token\" oauth.ssl.truststore.location=\"/etc/truststore/truststore.p12\" oauth.ssl.truststore.password=\"$TRUSTSTORE_PASSWORD\" oauth.ssl.truststore.type=\"PKCS12\" oauth.ssl.endpoint.identification.algorithm=\"\";"
```

## Automated Setup

You can use the complete setup script to automate most of the process:

```bash
./scripts/setup-complete.sh
```

This script will guide you through the entire setup process.

## Troubleshooting

### Application Not Consuming Messages

1. Check application logs: `kubectl logs -f deployment/quarkus-kafka-oauth`
2. Verify Keycloak client secret is correct
3. Verify Kafka OAuth listener is running: `kubectl get kafka kafka -o yaml`
4. Check topics exist: `kubectl get kafkatopics`
5. Check topic status: `kubectl describe kafkatopic my-source-events`

### Authentication Failures

1. Verify Keycloak is accessible from the Quarkus pod
2. Check the client secret in the Kubernetes secret
3. Verify the token endpoint URL is correct
4. Check Keycloak realm and client configuration

### Topic Not Found

1. Verify topics were created: `kubectl get kafkatopics`
2. Check topic status: `kubectl describe kafkatopic my-source-events`
3. Check Kafka cluster status: `kubectl get kafka`
4. Verify Entity Operator is running: `kubectl get pods -l strimzi.io/kind=entity-operator`
5. Re-apply topics if needed: `kubectl apply -f kafka/07-kafka-topics.yaml`

## Project Structure

```
.
├── 01-namespace.yaml          # OpenShift namespace
├── kafka/
│   ├── 02-kafka-instance.yaml              # Original Kafka config
│   ├── 02-kafka-instance-oauth.yaml        # OAuth-enabled Kafka config
│   └── 07-kafka-topics.yaml                # KafkaTopic custom resources
├── keycloak/
│   ├── 03-database-secrets.yaml
│   ├── 04-database.yaml
│   ├── 05-tls-secret.yaml
│   └── 06-keycloak-instance.yaml
├── quarkus/
│   ├── src/
│   │   ├── main/
│   │   │   ├── java/com/example/
│   │   │   │   └── EventProcessor.java     # Main event processing logic
│   │   │   └── resources/
│   │   │       └── application.properties  # Application configuration
│   ├── deployment.yaml                     # Kubernetes deployment
│   ├── buildconfig.yaml                    # OpenShift BuildConfig (binary build)
│   ├── imagestream.yaml                    # OpenShift ImageStream
│   ├── Dockerfile.native                   # Native image Dockerfile
│   └── pom.xml
└── scripts/
    ├── configure-keycloak.sh              # Keycloak setup
    ├── build-quarkus-openshift.sh         # OpenShift native build
    ├── setup-kafka-acls.sh                # ACL configuration
    └── setup-complete.sh                  # Complete setup automation
```

## Notes

- The OAuth listener uses port 9094 (different from the TLS listener on 9093)
- Make sure Keycloak TLS certificates are properly configured
- The application processes JSON events and adds metadata (processed flag, timestamp)
- Adjust the event processing logic in `EventProcessor.java` as needed
- The Quarkus application is built as a native executable on OpenShift for optimal performance and resource usage
- Native builds typically take 10-20 minutes due to GraalVM compilation

