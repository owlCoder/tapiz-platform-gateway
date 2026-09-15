# Tapiz Platform Gateway

Production Caddy gateway for services hosted on the Tapiz Platform VPS. It
terminates TLS, publishes ports 80 and 443, and routes each public hostname to
the appropriate service over a dedicated Docker edge network.

The gateway is intentionally limited to HTTP delivery. Authentication,
application logic, databases, queues, workers, and schedulers remain owned by
their respective services and private networks.

## Architecture

```text
Internet
    |
    +-- :80 / :443 --> Caddy gateway
                            |
                            +-- tapiz-edge  --> Tapiz API lanes
                            +-- aura-edge   --> Aura API and media delivery
                            +-- boards-edge --> Boards application
```

Only the `caddy` service publishes host ports. Each product keeps its own
private infrastructure off the gateway networks; the gateway connects only to
the HTTP upstreams it must serve.

## Routes

| Hostname | Upstream | Notes |
| --- | --- | --- |
| `TAPIZ_API_DOMAIN` | Tapiz API lanes | Login requests are balanced between two auth replicas; scan requests use the scan lane; other API traffic uses the general lane. |
| `AURA_API_DOMAIN` | Aura API and media delivery | `/hls/*` is served by the media service; all other paths go to the Aura API. |
| `BOARDS_API_DOMAIN` | Boards application | All traffic is routed to the Boards application. |

All domains, network names, and upstream aliases are configured through
environment variables and the Caddy site fragments in `sites/`.

## Prerequisites

- Docker Engine with Docker Compose v2
- Ports 80 and 443 available on the host
- Public DNS records for each configured hostname pointing to the VPS
- The external product networks already created
- Product HTTP containers connected to their edge network with the aliases
  expected by the corresponding `sites/*.caddy` file

## Configure and run

Create the local configuration file and set production values:

```sh
cp .env.example .env
```

At minimum, provide real values for `CADDY_EMAIL` and the public domain
variables. The edge-network variables may be changed when a deployment uses
different Docker network names.

Start the gateway:

```sh
docker compose up -d
```

Follow logs and inspect the running service:

```sh
docker compose logs -f caddy
docker compose ps
```

## Validate and reload configuration

Validate the Compose and Caddy configuration before deployment:

```sh
./tests/validate.sh
```

After changing a Caddy configuration file, validate and reload without
restarting the gateway container:

```sh
docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

## Add a product

1. Create a dedicated external Docker edge network for the product.
2. Connect only the product's public HTTP services to that network.
3. Assign stable, product-specific Docker network aliases to those services.
4. Add a site fragment under `sites/` and import any shared policy from
   `snippets/`.
5. Add the network to `docker-compose.yml`, configure the domain in `.env`,
   then validate and reload Caddy.

Do not attach databases, caches, queues, workers, or other private services to
an edge network solely for gateway access. Do not use container IP addresses;
service aliases are the supported upstream contract.

## Security defaults

The gateway applies response compression and common browser security headers.
The Caddy admin API remains inside the container, the service runs with a
read-only configuration mount, and Docker capabilities are reduced to the
minimum needed to bind HTTP and HTTPS ports.

## Repository layout

```text
Caddyfile             Main Caddy configuration
docker-compose.yml    Gateway service, persistent volumes, and edge networks
sites/                Product-specific host and route definitions
snippets/             Shared Caddy directives
tests/validate.sh     Local configuration validation
tests/integration/    Disposable integration checks
```
