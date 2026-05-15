# Portainer Swarm VPS Installer

Production-oriented VPS bootstrap for Docker Swarm with Traefik, Portainer, Dozzle, Docker log rotation, overlay networks, persistent volumes, and node join workflows.

## What It Installs

- Docker Engine, if missing
- Docker Swarm
- Traefik with Let's Encrypt and dashboard enabled
- Portainer CE behind Traefik
- Portainer Agent as a global Swarm service
- Dozzle as a global Swarm service with simple auth
- Docker log rotation using `json-file`, `50m`, `5` files
- Overlay networks: `public`, `agent_network`, `dozzle_network`
- Volumes: `portainer_data`, `traefik_letsencrypt`
- Optional UFW firewall rules

## Bootstrap First VPS

Set DNS records for these hostnames to point at your VPS first:

- `portainer.example.com`
- `logs.example.com`
- `traefik.example.com`

Run:

```sh
PORTAINER_DOMAIN=portainer.example.com \
DOZZLE_DOMAIN=logs.example.com \
TRAEFIK_DOMAIN=traefik.example.com \
TRAEFIK_ACME_EMAIL=admin@example.com \
sh install.sh
```

For remote one-line usage after hosting the script:

```sh
curl -sSL https://your-domain.com/install.sh | \
  PORTAINER_DOMAIN=portainer.example.com \
  DOZZLE_DOMAIN=logs.example.com \
  TRAEFIK_DOMAIN=traefik.example.com \
  TRAEFIK_ACME_EMAIL=admin@example.com \
  INSTALLER_URL=https://your-domain.com/install.sh \
  sh
```

## Join Another VPS

After bootstrap, check `/opt/portainer-platform/join-worker.sh` and `/opt/portainer-platform/join-manager.sh` on the manager.

The generic form is:

```sh
curl -sSL https://your-domain.com/install.sh | \
  SWARM_JOIN_TOKEN=xxx \
  SWARM_MANAGER_ADDR=1.2.3.4:2377 \
  sh
```

## Important Variables

```sh
PORTAINER_DOMAIN=portainer.example.com
DOZZLE_DOMAIN=logs.example.com
TRAEFIK_DOMAIN=traefik.example.com
TRAEFIK_ACME_EMAIL=admin@example.com
INSTALLER_URL=https://your-domain.com/install.sh
PORTAINER_TRUSTED_ORIGINS=https://portainer.example.com

ADVERTISE_ADDR=10.0.0.10
TRUSTED_NODE_CIDR=10.0.0.0/8

ENABLE_UFW=false
CONFIGURE_FIREWALL=true

PORTAINER_ADMIN_PASSWORD=optional-custom-password
DOZZLE_ADMIN_PASSWORD=optional-custom-password
TRAEFIK_DASHBOARD_PASSWORD=optional-custom-password

REDEPLOY=true
```

## Firewall Notes

The script allows public `80/tcp`, `443/tcp`, and `22/tcp` when UFW exists.

For multi-node Swarm, set `TRUSTED_NODE_CIDR` so the script can allow Swarm traffic only between trusted nodes:

- `2377/tcp`
- `7946/tcp`
- `7946/udp`
- `4789/udp`
- `9001/tcp`

The script does not enable UFW unless `ENABLE_UFW=true` is set.

## Files Created

```text
/opt/portainer-platform/
├── install.env
├── platform-stack.yml
├── join-worker.sh
├── join-manager.sh
└── dozzle/users.yml
```

## Verify

```sh
docker service ls
docker stack ps platform
docker network ls
docker volume ls
```
