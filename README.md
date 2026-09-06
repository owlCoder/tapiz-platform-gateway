# Platform VPS Gateway

One Caddy instance owns public ports 80/443 for every product hosted on the
same VPS. It is independent of the Aura Beats and Tapiz LMS Compose projects.
It provides TLS, host/path routing, health checks and JSON access logs; it does
not contain application authorization, database access or business logic.

## Network boundary

The gateway joins one small external edge network per product:

```text
platform-gateway/caddy ── tapiz-edge ── Tapiz public API lanes only
                       └─ aura-edge  ── Aura API + media delivery only
```

Tapiz PostgreSQL, Valkey, PgBouncer, worker and scheduler stay on Tapiz's
private network. Aura PostgreSQL and workers stay on Aura's private network.
Products do not join each other's edge networks.

## Product integration contract

Before a product is attached, its Compose configuration must:

1. Create or join its named external edge network.
2. Attach only HTTP upstreams that the gateway needs.
3. Give them stable, product-prefixed aliases. This gateway expects:
   - Tapiz: `tapiz-auth-api-1`, `tapiz-auth-api-2`, `tapiz-scan-api`,
     `tapiz-general-api`.
   - Aura: `aura-api`, `aura-media-delivery`.
4. Remove all product-level host bindings for ports 80/443.

Never use Docker container IP addresses. Product private databases and queues
must not be attached to an edge network merely for convenience.

## Adding or removing a product

To add a product, create its external edge network, attach the gateway and its
public HTTP containers, then add one `sites/<product>.caddy` fragment. Validate
and reload Caddy before exposing its DNS record.

To remove a product, remove its fragment and reload Caddy, then stop/remove
that product's Compose stack. Other sites remain served. If a product is merely
down while its fragment remains, only that product's hostname returns an
upstream failure; it cannot take down Tapiz or Aura.

## Local validation

```sh
cp .env.example .env
./tests/validate.sh
```

The validation command checks Compose interpolation and parses the full Caddy
configuration. It does not create Docker networks, bind ports, contact a VPS or
issue certificates.

## Future VPS activation

This repository is configuration only. Actual VPS activation requires a
separate approved change: create the two edge networks, update Aura/Tapiz
Compose network attachments, move their Caddy path rules here, stop their
product-level Caddy containers, start this gateway, then validate each public
hostname. Do not perform those operations against the current host merely by
following this document.
