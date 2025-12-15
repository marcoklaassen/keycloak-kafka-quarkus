package com.example;

import jakarta.enterprise.context.ApplicationScoped;
import org.eclipse.microprofile.reactive.messaging.Incoming;
import org.eclipse.microprofile.reactive.messaging.Outgoing;
import org.jboss.logging.Logger;

import jakarta.json.Json;
import jakarta.json.JsonObject;
import jakarta.json.JsonReader;
import java.io.StringReader;

@ApplicationScoped
public class EventProcessor {

    private static final Logger LOG = Logger.getLogger(EventProcessor.class);

    @Incoming("source-events")
    @Outgoing("target-events")
    public String processEvent(String event) {
        LOG.infof("Received event from source topic: %s", event);
        
        try {
            // Parse the incoming event
            JsonReader reader = Json.createReader(new StringReader(event));
            JsonObject jsonEvent = reader.readObject();
            reader.close();

            // Process the event (example: add a processed timestamp and transform data)
            JsonObject processedEvent = Json.createObjectBuilder(jsonEvent)
                    .add("processed", true)
                    .add("processedTimestamp", System.currentTimeMillis())
                    .add("processor", "quarkus-kafka-oauth-app")
                    .build();

            String result = processedEvent.toString();
            LOG.infof("Processed event, sending to target topic: %s", result);
            
            return result;
        } catch (Exception e) {
            LOG.errorf(e, "Error processing event: %s", event);
            // In case of error, still forward the original event
            return event;
        }
    }
}

