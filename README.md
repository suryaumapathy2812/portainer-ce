# Portainer Swarm VPS Installer

Production-oriented VPS bootstrap for Docker Swarm with Traefik, Portainer, Dozzle, Docker log rotation, overlay networks, persistent volumes, and node join workflows.

## Scripts

- `all-in-one.sh`: first VPS with Swarm manager, Traefik, Portainer Server, Portainer Agent, and Dozzle
- `server.sh`: control-plane VPS with Swarm manager, Traefik, Portainer Server, and Dozzle, but no Portainer Agent service
- `agent.sh`: agent/worker VPS only; installs Docker, configures log rotation/firewall, and joins an existing Swarm
- `install.sh`: underlying installer used by the scripts above

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

- `portainer.yourdomain.com`
- `logs.yourdomain.com`
- `traefik.yourdomain.com`

Recommended one-line install:

```sh
curl -sSL https://raw.githubusercontent.com/suryaumapathy2812/portainer-ce/main/install.sh | \
  DOMAIN=yourdomain.com \
  ACME_EMAIL=admin@yourdomain.com \
  DEPLOY_AGENT=true \
  INSTALLER_URL=https://raw.githubusercontent.com/suryaumapathy2812/portainer-ce/main/install.sh \
  sh
```

Clone and run all-in-one:

```sh
git clone https://github.com/suryaumapathy2812/portainer-ce.git
cd portainer-ce
DOMAIN=yourdomain.com \
ACME_EMAIL=admin@yourdomain.com \
sh all-in-one.sh
```

Clone and run server-only:

```sh
git clone https://github.com/suryaumapathy2812/portainer-ce.git
cd portainer-ce
DOMAIN=yourdomain.com \
ACME_EMAIL=admin@yourdomain.com \
sh server.sh
```

## Join Another VPS

After bootstrap, check `/opt/platform/join-worker.sh` and `/opt/platform/join-manager.sh` on the manager.

The generic form is:

```sh
curl -sSL https://raw.githubusercontent.com/suryaumapathy2812/portainer-ce/main/install.sh | \
  SWARM_JOIN_TOKEN=xxx \
  SWARM_MANAGER_ADDR=1.2.3.4:2377 \
  sh
```

## Important Variables

```sh
DOMAIN=yourdomain.com
ACME_EMAIL=admin@yourdomain.com
INSTALLER_URL=https://raw.githubusercontent.com/suryaumapathy2812/portainer-ce/main/install.sh
PORTAINER_TRUSTED_ORIGINS=optional-comma-separated-origins

PORTAINER_DOMAIN=portainer.yourdomain.com
DOZZLE_DOMAIN=logs.yourdomain.com
TRAEFIK_DOMAIN=traefik.yourdomain.com

ADVERTISE_ADDR=10.0.0.10
TRUSTED_NODE_CIDR=10.0.0.0/8

ENABLE_UFW=false
CONFIGURE_FIREWALL=true
DEPLOY_AGENT=true

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

## Cloudflare And TLS

Before the first install, create these Cloudflare DNS records and point them to your VPS public IP:

- `A portainer`
- `A logs`
- `A traefik`

Set each record to **DNS only** until Traefik has issued Let's Encrypt certificates. The default Traefik config uses the Let's Encrypt HTTP-01 challenge, so port `80/tcp` must reach the VPS directly.

In Cloudflare SSL/TLS, use **Full** or **Full (strict)**. Do not use **Flexible**.

If a site loads but the browser says it is not secure, check the certificate issuer. If it says `TRAEFIK DEFAULT CERT`, Let's Encrypt has not issued yet. Check Traefik logs:

```sh
docker service logs platform_traefik --tail 100
```

Common causes are:

- Cloudflare record is proxied before the first certificate is issued
- Port `80/tcp` is blocked by the VPS firewall or provider firewall
- DNS has not propagated to the VPS IP yet
- The hostname does not match `DOMAIN`, `PORTAINER_DOMAIN`, `DOZZLE_DOMAIN`, or `TRAEFIK_DOMAIN`

After certificates are issued and HTTPS works, you may switch Cloudflare proxy on if desired. Keep SSL/TLS mode on **Full** or **Full (strict)**.

## Repair Existing Install

If an earlier generated stack has `--trusted-origins` under the Portainer command, remove those two lines from `/opt/platform/platform-stack.yml`:

```yaml
- --trusted-origins
- https://portainer.yourdomain.com
```

Then redeploy:

```sh
docker stack deploy -c /opt/platform/platform-stack.yml platform
```

If Portainer is currently crash-looping from trusted origins, repair the running service immediately:

```sh
docker service update \
  --args '-H tcp://tasks.agent:9001 --tlsskipverify --http-enabled --admin-password-file /run/secrets/portainer_admin_password' \
  platform_portainer
```

## Files Created

```text
/opt/platform/
├── install.env
├── platform-stack.yml
├── join-worker.sh
└── join-manager.sh

/opt/traefik/
├── traefik.yml
└── dynamic/middlewares.yml

/opt/dozzle/
├── users.yml
└── data/

/opt/portainer/
```

## Traefik Config

Static Traefik configuration is written to:

```text
/opt/traefik/traefik.yml
```

Dynamic config is written to:

```text
/opt/traefik/dynamic/
```

To add a new public Traefik entrypoint, edit `/opt/traefik/traefik.yml`, add the matching published port in `/opt/platform/platform-stack.yml`, then redeploy:

```sh
docker stack deploy -c /opt/platform/platform-stack.yml platform
```

## Verify

```sh
docker service ls
docker stack ps platform
docker network ls
docker volume ls
```
