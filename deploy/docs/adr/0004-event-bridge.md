# ADR 0004: how Fineract events reach Malipopay

**Status** accepted, 2026-09-09. Not implemented until phase 4.

## Problem

Fineract can emit business events. Malipopay's broker is RabbitMQ. Fineract has producers for
Kafka and for JMS, and none for RabbitMQ.

There is a second problem behind that one: payloads are Avro, with schemas in
`fineract-avro-schemas`, not JSON. A consumer written against a JSON assumption will not
work.

## Options

**Kafka.** What upstream tests most. But it is a second broker to run, back up and monitor on
a single droplet, for an event volume measured in thousands a day.

**ActiveMQ with a JMS producer,** consumed over STOMP by the banking middleware, which
decodes Avro and republishes canonical `banking.*` events onto the existing RabbitMQ vhost.
One more container, and the existing broker keeps being the only broker Malipopay services
know about.

**No events at all.** The middleware is the writer for everything it initiates, so it already
knows the outcome of its own calls synchronously.

## Decision

No events until phase 4, then ActiveMQ.

Through the funding and withdrawal work, the middleware initiates every posting and reads the
result from the response. Events add nothing to a flow whose writer is already listening, and
a component that carries no traffic yet still fails and still needs watching.

Phase 4 brings the flows the middleware does not initiate: interest posting, loan accrual,
delinquency transitions, close-of-business outcomes. Those are the ones worth an event, and
`docker-compose.events.yml` is ready and off.

Note that events are also disabled by default upstream and need `FINERACT_EXTERNAL_EVENTS_ENABLED`
turned on deliberately, with a producer chosen. Nothing here happens by accident.

## Revisit when

Event volume outgrows a single broker, or a second core banking system arrives with a
different transport, at which point normalising in the adapter rather than in the consumer
becomes the better shape.
