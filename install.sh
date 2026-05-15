#!/usr/bin/env sh
set -eu

APP_DIR="${APP_DIR:-/opt/portainer-platform}"
STACK_NAME="${STACK_NAME:-platform}"
INSTALLER_URL="${INSTALLER_URL:-<installer-url>}"

PORTAINER_DOMAIN="${PORTAINER_DOMAIN:-}"
DOZZLE_DOMAIN="${DOZZLE_DOMAIN:-}"
TRAEFIK_DOMAIN="${TRAEFIK_DOMAIN:-}"
TRAEFIK_ACME_EMAIL="${TRAEFIK_ACME_EMAIL:-}"

PORTAINER_TAG="${PORTAINER_TAG:-lts}"
PORTAINER_AGENT_TAG="${PORTAINER_AGENT_TAG:-lts}"
PORTAINER_TRUSTED_ORIGINS="${PORTAINER_TRUSTED_ORIGINS:-}"
DOZZLE_TAG="${DOZZLE_TAG:-latest}"
TRAEFIK_TAG="${TRAEFIK_TAG:-v3.6}"

ADVERTISE_ADDR="${ADVERTISE_ADDR:-}"
DATA_PATH_ADDR="${DATA_PATH_ADDR:-}"
DOCKER_SWARM_INIT_ARGS="${DOCKER_SWARM_INIT_ARGS:-}"
TRUSTED_NODE_CIDR="${TRUSTED_NODE_CIDR:-}"

SWARM_JOIN_TOKEN="${SWARM_JOIN_TOKEN:-}"
SWARM_MANAGER_ADDR="${SWARM_MANAGER_ADDR:-}"
SWARM_JOIN_AS="${SWARM_JOIN_AS:-worker}"

PORTAINER_ADMIN_PASSWORD="${PORTAINER_ADMIN_PASSWORD:-}"
DOZZLE_ADMIN_USER="${DOZZLE_ADMIN_USER:-admin}"
DOZZLE_ADMIN_PASSWORD="${DOZZLE_ADMIN_PASSWORD:-}"
DOZZLE_ADMIN_EMAIL="${DOZZLE_ADMIN_EMAIL:-admin@example.com}"
TRAEFIK_DASHBOARD_USER="${TRAEFIK_DASHBOARD_USER:-admin}"
TRAEFIK_DASHBOARD_PASSWORD="${TRAEFIK_DASHBOARD_PASSWORD:-}"

ENABLE_EDGE="${ENABLE_EDGE:-false}"
PORTAINER_EDGE_DOMAIN="${PORTAINER_EDGE_DOMAIN:-}"
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-true}"
ENABLE_UFW="${ENABLE_UFW:-false}"
CONFIGURE_LOG_ROTATION="${CONFIGURE_LOG_ROTATION:-true}"
DOCKER_LOG_ROTATION_FORCE="${DOCKER_LOG_ROTATION_FORCE:-false}"
SKIP_DOCKER_INSTALL="${SKIP_DOCKER_INSTALL:-false}"
REDEPLOY="${REDEPLOY:-false}"

PUBLIC_NETWORK="${PUBLIC_NETWORK:-public}"
AGENT_NETWORK="${AGENT_NETWORK:-agent_network}"
DOZZLE_NETWORK="${DOZZLE_NETWORK:-dozzle_network}"

PORTAINER_VOLUME="${PORTAINER_VOLUME:-portainer_data}"
TRAEFIK_VOLUME="${TRAEFIK_VOLUME:-traefik_letsencrypt}"

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_root() {
  [ "$(id -u)" = "0" ]
}

require_root_linux() {
  is_root || fail "this script must be run as root"
  [ "$(uname -s)" = "Linux" ] || fail "this script must be run on Linux"
}

bool_true() {
  case "$1" in
    true|TRUE|1|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

generate_password() {
  if command_exists openssl; then
    openssl rand -base64 36 | tr -d '=+/' | cut -c1-32
  elif [ -r /dev/urandom ]; then
    tr -dc 'A-Za-z0-9' </dev/urandom | dd bs=32 count=1 2>/dev/null
  else
    date +%s | sha256sum | cut -c1-32
  fi
}

get_private_ip() {
  ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -n1 || true
}

get_public_ip() {
  ip=""
  ip=$(curl -4fsS --connect-timeout 5 https://ifconfig.io 2>/dev/null || true)
  [ -n "$ip" ] || ip=$(curl -4fsS --connect-timeout 5 https://icanhazip.com 2>/dev/null || true)
  [ -n "$ip" ] || ip=$(curl -4fsS --connect-timeout 5 https://ipecho.net/plain 2>/dev/null || true)
  printf '%s' "$ip" | tr -d '[:space:]'
}

detect_advertise_addr() {
  if [ -n "$ADVERTISE_ADDR" ]; then
    printf '%s' "$ADVERTISE_ADDR"
    return
  fi

  private_ip=$(get_private_ip)
  if [ -n "$private_ip" ]; then
    printf '%s' "$private_ip"
    return
  fi

  public_ip=$(get_public_ip)
  [ -n "$public_ip" ] || fail "could not detect advertise address. Set ADVERTISE_ADDR manually."
  printf '%s' "$public_ip"
}

install_docker() {
  if command_exists docker; then
    log "Docker already installed"
    return
  fi

  bool_true "$SKIP_DOCKER_INSTALL" && fail "Docker is not installed and SKIP_DOCKER_INSTALL=true"
  command_exists curl || fail "curl is required to install Docker"

  log "Installing Docker Engine"
  curl -fsSL https://get.docker.com | sh
}

start_docker() {
  if command_exists systemctl; then
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
  fi

  docker info >/dev/null 2>&1 || fail "Docker is not running or is not usable"
}

configure_log_rotation() {
  bool_true "$CONFIGURE_LOG_ROTATION" || return

  mkdir -p /etc/docker
  if [ -f /etc/docker/daemon.json ] && ! bool_true "$DOCKER_LOG_ROTATION_FORCE"; then
    if grep -q '"log-opts"' /etc/docker/daemon.json 2>/dev/null; then
      log "Docker log rotation already appears configured"
      return
    fi
    warn "/etc/docker/daemon.json exists and has no log-opts; leaving it unchanged. Set DOCKER_LOG_ROTATION_FORCE=true to replace it with a backup."
    return
  fi

  if [ -f /etc/docker/daemon.json ]; then
    cp /etc/docker/daemon.json "/etc/docker/daemon.json.$(date +%Y%m%d%H%M%S).bak"
  fi

  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  }
}
EOF

  if command_exists systemctl; then
    systemctl restart docker
  else
    service docker restart >/dev/null 2>&1 || true
  fi

  docker info >/dev/null 2>&1 || fail "Docker failed after configuring log rotation"
  log "Docker log rotation configured"
}

configure_firewall() {
  bool_true "$CONFIGURE_FIREWALL" || return

  if ! command_exists ufw; then
    warn "ufw not found; skipping firewall configuration"
    return
  fi

  log "Configuring ufw firewall rules"
  ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true

  if [ -n "$TRUSTED_NODE_CIDR" ]; then
    ufw allow from "$TRUSTED_NODE_CIDR" to any port 2377 proto tcp >/dev/null 2>&1 || true
    ufw allow from "$TRUSTED_NODE_CIDR" to any port 7946 proto tcp >/dev/null 2>&1 || true
    ufw allow from "$TRUSTED_NODE_CIDR" to any port 7946 proto udp >/dev/null 2>&1 || true
    ufw allow from "$TRUSTED_NODE_CIDR" to any port 4789 proto udp >/dev/null 2>&1 || true
    ufw allow from "$TRUSTED_NODE_CIDR" to any port 9001 proto tcp >/dev/null 2>&1 || true
  else
    warn "TRUSTED_NODE_CIDR not set; Swarm inter-node ports were not opened. Set it for multi-node clusters."
  fi

  if bool_true "$ENABLE_UFW"; then
    ufw --force enable >/dev/null 2>&1 || true
  fi
}

swarm_state() {
  docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || printf 'inactive'
}

init_swarm() {
  state=$(swarm_state)
  if [ "$state" = "active" ]; then
    log "Docker Swarm already active"
    return
  fi

  advertise_addr=$(detect_advertise_addr)
  cmd="docker swarm init --advertise-addr $advertise_addr"
  if [ -n "$DATA_PATH_ADDR" ]; then
    cmd="$cmd --data-path-addr $DATA_PATH_ADDR"
  fi
  if [ -n "$DOCKER_SWARM_INIT_ARGS" ]; then
    cmd="$cmd $DOCKER_SWARM_INIT_ARGS"
  fi

  log "Initializing Docker Swarm with advertise address $advertise_addr"
  sh -c "$cmd"
}

join_swarm() {
  [ -n "$SWARM_JOIN_TOKEN" ] || fail "SWARM_JOIN_TOKEN is required in join mode"
  [ -n "$SWARM_MANAGER_ADDR" ] || fail "SWARM_MANAGER_ADDR is required in join mode"

  state=$(swarm_state)
  if [ "$state" = "active" ]; then
    log "This node is already part of a Swarm"
    return
  fi

  advertise_arg=""
  if [ -n "$ADVERTISE_ADDR" ]; then
    advertise_arg="--advertise-addr $ADVERTISE_ADDR"
  fi

  data_path_arg=""
  if [ -n "$DATA_PATH_ADDR" ]; then
    data_path_arg="--data-path-addr $DATA_PATH_ADDR"
  fi

  log "Joining Docker Swarm as $SWARM_JOIN_AS"
  mkdir -p /opt/dozzle/data
  docker swarm join --token "$SWARM_JOIN_TOKEN" $advertise_arg $data_path_arg "$SWARM_MANAGER_ADDR"
}

ensure_network() {
  name="$1"
  encrypted="$2"
  if docker network inspect "$name" >/dev/null 2>&1; then
    return
  fi

  if bool_true "$encrypted"; then
    docker network create --driver overlay --attachable --opt encrypted "$name" >/dev/null
  else
    docker network create --driver overlay --attachable "$name" >/dev/null
  fi
}

ensure_volume() {
  name="$1"
  docker volume inspect "$name" >/dev/null 2>&1 || docker volume create "$name" >/dev/null
}

ensure_secret_from_file() {
  name="$1"
  file="$2"
  if docker secret inspect "$name" >/dev/null 2>&1; then
    return
  fi
  docker secret create "$name" "$file" >/dev/null
}

ensure_secret_from_stdin() {
  name="$1"
  value="$2"
  if docker secret inspect "$name" >/dev/null 2>&1; then
    return
  fi
  printf '%s' "$value" | docker secret create "$name" - >/dev/null
}

escape_basic_auth_hash() {
  printf '%s' "$1" | sed 's/\$/$$/g'
}

generate_basic_auth_hash() {
  user="$1"
  password="$2"
  docker run --rm httpd:2.4-alpine htpasswd -nbB "$user" "$password" | sed 's/\$/$$/g'
}

generate_dozzle_users() {
  user="$1"
  password="$2"
  email="$3"
  docker run --rm amir20/dozzle:"$DOZZLE_TAG" generate "$user" --password "$password" --email "$email" --name "Admin"
}

validate_bootstrap_inputs() {
  [ -n "$PORTAINER_DOMAIN" ] || fail "PORTAINER_DOMAIN is required"
  [ -n "$DOZZLE_DOMAIN" ] || fail "DOZZLE_DOMAIN is required"
  [ -n "$TRAEFIK_DOMAIN" ] || fail "TRAEFIK_DOMAIN is required"
  [ -n "$TRAEFIK_ACME_EMAIL" ] || fail "TRAEFIK_ACME_EMAIL is required"

  if bool_true "$ENABLE_EDGE" && [ -z "$PORTAINER_EDGE_DOMAIN" ]; then
    fail "PORTAINER_EDGE_DOMAIN is required when ENABLE_EDGE=true"
  fi

  if [ -z "$PORTAINER_TRUSTED_ORIGINS" ]; then
    PORTAINER_TRUSTED_ORIGINS="https://$PORTAINER_DOMAIN"
  fi
}

prepare_platform_files() {
  mkdir -p "$APP_DIR" "$APP_DIR/dozzle"
  chmod 700 "$APP_DIR"
}

prepare_secrets() {
  if [ -z "$PORTAINER_ADMIN_PASSWORD" ]; then
    PORTAINER_ADMIN_PASSWORD=$(generate_password)
    GENERATED_PORTAINER_PASSWORD="true"
  else
    GENERATED_PORTAINER_PASSWORD="false"
  fi

  if [ -z "$DOZZLE_ADMIN_PASSWORD" ]; then
    DOZZLE_ADMIN_PASSWORD=$(generate_password)
    GENERATED_DOZZLE_PASSWORD="true"
  else
    GENERATED_DOZZLE_PASSWORD="false"
  fi

  if [ -z "$TRAEFIK_DASHBOARD_PASSWORD" ]; then
    TRAEFIK_DASHBOARD_PASSWORD=$(generate_password)
    GENERATED_TRAEFIK_PASSWORD="true"
  else
    GENERATED_TRAEFIK_PASSWORD="false"
  fi

  ensure_secret_from_stdin "portainer_admin_password" "$PORTAINER_ADMIN_PASSWORD"

  generate_dozzle_users "$DOZZLE_ADMIN_USER" "$DOZZLE_ADMIN_PASSWORD" "$DOZZLE_ADMIN_EMAIL" > "$APP_DIR/dozzle/users.yml"
  chmod 600 "$APP_DIR/dozzle/users.yml"
  ensure_secret_from_file "dozzle_users" "$APP_DIR/dozzle/users.yml"

  TRAEFIK_BASIC_AUTH=$(generate_basic_auth_hash "$TRAEFIK_DASHBOARD_USER" "$TRAEFIK_DASHBOARD_PASSWORD")
  export TRAEFIK_BASIC_AUTH GENERATED_PORTAINER_PASSWORD GENERATED_DOZZLE_PASSWORD GENERATED_TRAEFIK_PASSWORD
}

write_stack_file() {
  stack_file="$APP_DIR/$STACK_NAME-stack.yml"

  edge_labels=""
  if bool_true "$ENABLE_EDGE"; then
    edge_labels="
        - traefik.http.routers.portainer-edge.rule=Host(\`$PORTAINER_EDGE_DOMAIN\`)
        - traefik.http.routers.portainer-edge.entrypoints=websecure
        - traefik.http.routers.portainer-edge.tls=true
        - traefik.http.routers.portainer-edge.tls.certresolver=letsencrypt
        - traefik.http.routers.portainer-edge.service=portainer-edge
        - traefik.http.services.portainer-edge.loadbalancer.server.port=8000"
  fi

  cat > "$stack_file" <<EOF
version: "3.8"

services:
  traefik:
    image: traefik:$TRAEFIK_TAG
    command:
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --providers.swarm=true
      - --providers.swarm.endpoint=unix:///var/run/docker.sock
      - --providers.swarm.exposedbydefault=false
      - --providers.swarm.network=$PUBLIC_NETWORK
      - --api.dashboard=true
      - --ping=true
      - --certificatesresolvers.letsencrypt.acme.email=$TRAEFIK_ACME_EMAIL
      - --certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.letsencrypt.acme.httpchallenge=true
      - --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web
      - --log.level=INFO
      - --accesslog=true
    ports:
      - target: 80
        published: 80
        protocol: tcp
        mode: ingress
      - target: 443
        published: 443
        protocol: tcp
        mode: ingress
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - $TRAEFIK_VOLUME:/letsencrypt
    networks:
      - $PUBLIC_NETWORK
    deploy:
      placement:
        constraints:
          - node.role == manager
      labels:
        - traefik.enable=true
        - traefik.swarm.network=$PUBLIC_NETWORK
        - traefik.http.routers.traefik.rule=Host(\`$TRAEFIK_DOMAIN\`)
        - traefik.http.routers.traefik.entrypoints=websecure
        - traefik.http.routers.traefik.tls=true
        - traefik.http.routers.traefik.tls.certresolver=letsencrypt
        - traefik.http.routers.traefik.service=api@internal
        - traefik.http.routers.traefik.middlewares=traefik-auth
        - traefik.http.middlewares.traefik-auth.basicauth.users=$TRAEFIK_BASIC_AUTH

  agent:
    image: portainer/agent:$PORTAINER_AGENT_TAG
    environment:
      AGENT_CLUSTER_ADDR: tasks.agent
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /var/lib/docker/volumes:/var/lib/docker/volumes
    networks:
      - $AGENT_NETWORK
    deploy:
      mode: global
      placement:
        constraints:
          - node.platform.os == linux

  portainer:
    image: portainer/portainer-ce:$PORTAINER_TAG
    command:
      - -H
      - tcp://tasks.agent:9001
      - --tlsskipverify
      - --http-enabled
      - --admin-password-file
      - /run/secrets/portainer_admin_password
      - --trusted-origins
      - $PORTAINER_TRUSTED_ORIGINS
    secrets:
      - portainer_admin_password
    volumes:
      - $PORTAINER_VOLUME:/data
    networks:
      - $PUBLIC_NETWORK
      - $AGENT_NETWORK
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
      labels:
        - traefik.enable=true
        - traefik.swarm.network=$PUBLIC_NETWORK
        - traefik.http.routers.portainer.rule=Host(\`$PORTAINER_DOMAIN\`)
        - traefik.http.routers.portainer.entrypoints=websecure
        - traefik.http.routers.portainer.tls=true
        - traefik.http.routers.portainer.tls.certresolver=letsencrypt
        - traefik.http.routers.portainer.service=portainer
        - traefik.http.services.portainer.loadbalancer.server.port=9000$edge_labels

  dozzle:
    image: amir20/dozzle:$DOZZLE_TAG
    environment:
      DOZZLE_MODE: swarm
      DOZZLE_AUTH_PROVIDER: simple
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /opt/dozzle/data:/data
    secrets:
      - source: dozzle_users
        target: /data/users.yml
    networks:
      - $PUBLIC_NETWORK
      - $DOZZLE_NETWORK
    deploy:
      mode: global
      labels:
        - traefik.enable=true
        - traefik.swarm.network=$PUBLIC_NETWORK
        - traefik.http.routers.dozzle.rule=Host(\`$DOZZLE_DOMAIN\`)
        - traefik.http.routers.dozzle.entrypoints=websecure
        - traefik.http.routers.dozzle.tls=true
        - traefik.http.routers.dozzle.tls.certresolver=letsencrypt
        - traefik.http.routers.dozzle.service=dozzle
        - traefik.http.services.dozzle.loadbalancer.server.port=8080

networks:
  $PUBLIC_NETWORK:
    external: true
  $AGENT_NETWORK:
    external: true
  $DOZZLE_NETWORK:
    external: true

volumes:
  $PORTAINER_VOLUME:
    external: true
  $TRAEFIK_VOLUME:
    external: true

secrets:
  portainer_admin_password:
    external: true
  dozzle_users:
    external: true
EOF
}

write_env_file() {
  cat > "$APP_DIR/install.env" <<EOF
STACK_NAME=$STACK_NAME
PORTAINER_DOMAIN=$PORTAINER_DOMAIN
DOZZLE_DOMAIN=$DOZZLE_DOMAIN
TRAEFIK_DOMAIN=$TRAEFIK_DOMAIN
TRAEFIK_ACME_EMAIL=$TRAEFIK_ACME_EMAIL
PORTAINER_TAG=$PORTAINER_TAG
PORTAINER_AGENT_TAG=$PORTAINER_AGENT_TAG
PORTAINER_TRUSTED_ORIGINS=$PORTAINER_TRUSTED_ORIGINS
DOZZLE_TAG=$DOZZLE_TAG
TRAEFIK_TAG=$TRAEFIK_TAG
PUBLIC_NETWORK=$PUBLIC_NETWORK
AGENT_NETWORK=$AGENT_NETWORK
DOZZLE_NETWORK=$DOZZLE_NETWORK
PORTAINER_VOLUME=$PORTAINER_VOLUME
TRAEFIK_VOLUME=$TRAEFIK_VOLUME
EOF
  chmod 600 "$APP_DIR/install.env"
}

write_join_files() {
  manager_addr=$(docker node inspect self --format '{{.Status.Addr}}' 2>/dev/null || true)
  [ -n "$manager_addr" ] || manager_addr=$(detect_advertise_addr)

  worker_token=$(docker swarm join-token -q worker)
  manager_token=$(docker swarm join-token -q manager)

  cat > "$APP_DIR/join-worker.sh" <<EOF
#!/usr/bin/env sh
curl -sSL '$INSTALLER_URL' | SWARM_JOIN_TOKEN=$worker_token SWARM_MANAGER_ADDR=$manager_addr:2377 sh
EOF
  cat > "$APP_DIR/join-manager.sh" <<EOF
#!/usr/bin/env sh
curl -sSL '$INSTALLER_URL' | SWARM_JOIN_TOKEN=$manager_token SWARM_MANAGER_ADDR=$manager_addr:2377 SWARM_JOIN_AS=manager sh
EOF
  chmod 700 "$APP_DIR/join-worker.sh" "$APP_DIR/join-manager.sh"
}

deploy_stack() {
  if docker stack ls --format '{{.Name}}' | grep -qx "$STACK_NAME" && ! bool_true "$REDEPLOY"; then
    log "Stack $STACK_NAME already exists. Set REDEPLOY=true to deploy again."
    return
  fi

  docker stack deploy -c "$APP_DIR/$STACK_NAME-stack.yml" "$STACK_NAME"
}

bootstrap() {
  validate_bootstrap_inputs
  configure_log_rotation
  init_swarm
  configure_firewall

  prepare_platform_files
  mkdir -p /opt/dozzle/data

  ensure_network "$PUBLIC_NETWORK" false
  ensure_network "$AGENT_NETWORK" true
  ensure_network "$DOZZLE_NETWORK" true
  ensure_volume "$PORTAINER_VOLUME"
  ensure_volume "$TRAEFIK_VOLUME"

  prepare_secrets
  write_stack_file
  write_env_file
  write_join_files
  deploy_stack

  log ""
  log "Platform deployment requested. Services may take a minute to become healthy."
  log ""
  log "Portainer: https://$PORTAINER_DOMAIN"
  log "Dozzle:    https://$DOZZLE_DOMAIN"
  log "Traefik:   https://$TRAEFIK_DOMAIN"
  log ""
  log "Portainer username: admin"
  log "Portainer password: $PORTAINER_ADMIN_PASSWORD"
  log "Dozzle username:    $DOZZLE_ADMIN_USER"
  log "Dozzle password:    $DOZZLE_ADMIN_PASSWORD"
  log "Traefik username:   $TRAEFIK_DASHBOARD_USER"
  log "Traefik password:   $TRAEFIK_DASHBOARD_PASSWORD"
  log ""
  log "Stack file: $APP_DIR/$STACK_NAME-stack.yml"
  log "Join helpers: $APP_DIR/join-worker.sh and $APP_DIR/join-manager.sh"
  log ""
  log "Check status with: docker service ls"
}

main() {
  require_root_linux
  command_exists curl || fail "curl is required"
  install_docker
  start_docker

  if [ -n "$SWARM_JOIN_TOKEN" ] || [ -n "$SWARM_MANAGER_ADDR" ]; then
    configure_log_rotation
    configure_firewall
    join_swarm
    log "Node joined. The global Portainer Agent and Dozzle services should schedule automatically."
    exit 0
  fi

  bootstrap
}

main "$@"
