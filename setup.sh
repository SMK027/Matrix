#!/usr/bin/env bash
# ==============================================================================
# setup.sh — Configuration initiale du serveur Matrix Synapse
#
# Usage : bash setup.sh
#
# Ce script effectue dans l'ordre :
#   0. Installation automatique de Docker et Docker Compose si absents
#   1. Vérification des prérequis (Docker, Docker Compose)
#   2. Chargement et validation du fichier .env
#   3. Création des répertoires de données
#   4. Génération de la config nginx HTTP (pour le challenge Let's Encrypt)
#   5. Génération du homeserver.yaml de Synapse + configuration PostgreSQL
#   6. Démarrage de nginx (mode HTTP uniquement)
#   7. Obtention du certificat SSL via certbot (Let's Encrypt)
#   8. Remplacement par la config nginx HTTPS complète
#   9. Démarrage de tous les services
#  10. Création optionnelle d'un compte administrateur
# ==============================================================================
set -euo pipefail

# ── Couleurs ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}   $*"; }
success() { echo -e "${GREEN}[OK]${NC}     $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}   $*"; }
error()   { echo -e "${RED}[ERREUR]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

COMPOSE_CMD=""

resolve_compose_command() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
        return 0
    fi

    if command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
        return 0
    fi

    return 1
}

compose() {
    if [ -z "${COMPOSE_CMD}" ]; then
        resolve_compose_command || error "Aucune commande Compose disponible (docker compose ou docker-compose)."
    fi

    if [ "${COMPOSE_CMD}" = "docker compose" ]; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

# ── 0. Installation des dépendances ──────────────────────────────────────────
install_dependencies() {
    step "Installation des dépendances (Docker + Compose)"

    # Ce script nécessite les droits root pour installer des paquets
    if [ "$(id -u)" -ne 0 ]; then
        error "Ce script doit être exécuté en root ou avec sudo."
    fi

    if command -v docker >/dev/null 2>&1; then
        if resolve_compose_command; then
            success "Docker et Compose déjà installés — aucune action nécessaire."
        else
            error "Docker est déjà installé mais aucune commande Compose n'a été trouvée. Par sécurité, le script n'altère pas une installation Docker existante sur un VPS en production. Installez docker-compose ou le plugin Docker Compose, puis relancez le script."
        fi
    fi

    # Détection de la distribution
    local distro="unknown"
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        distro=$(. /etc/os-release && echo "${ID:-unknown}")
    fi

    case "$distro" in
        debian|ubuntu|linuxmint|pop|raspbian)
            _install_docker_apt
            ;;
        centos|rhel|fedora|rocky|almalinux)
            _install_docker_dnf
            ;;
        *)
            warn "Distribution '${distro}' non reconnue — vérification manuelle..."
            ;;
    esac

    # Vérification finale après tentative d'installation
    command -v docker >/dev/null 2>&1 \
        || error "Docker introuvable après installation. Installez-le manuellement : https://docs.docker.com/engine/install/"
    resolve_compose_command \
        || error "Aucune commande Compose disponible après installation. Installez docker-compose ou le plugin Docker Compose."

    # S'assurer que le démon Docker tourne
    if ! docker info >/dev/null 2>&1; then
        info "Démarrage du service Docker..."
        systemctl enable --now docker
    fi

    success "Docker       : $(docker --version | awk '{print $3}' | tr -d ',')"
    if [ "${COMPOSE_CMD}" = "docker compose" ]; then
        success "Compose      : $(docker compose version --short)"
    else
        success "Compose      : $(docker-compose version --short 2>/dev/null || docker-compose version | head -n1)"
    fi
}

_install_docker_apt() {
    # ── Debian / Ubuntu ──────────────────────────────────────────────────────
    info "Mise à jour des dépôts APT..."
    apt-get update -qq

    info "Installation des paquets requis..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ca-certificates curl gnupg lsb-release

    # Clé GPG officielle Docker
    install -m 0755 -d /etc/apt/keyrings
    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        info "Ajout de la clé GPG Docker..."
        curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    # Dépôt officiel Docker
    if [ ! -f /etc/apt/sources.list.d/docker.list ]; then
        info "Ajout du dépôt Docker..."
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
    fi

    info "Installation de Docker Engine + Compose plugin..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    success "Docker installé via le dépôt officiel."
}

_install_docker_dnf() {
    # ── RHEL / CentOS / Fedora ───────────────────────────────────────────────
    local pkg_manager="dnf"
    command -v dnf >/dev/null 2>&1 || pkg_manager="yum"

    info "Ajout du dépôt Docker CE pour RHEL/Fedora..."
    $pkg_manager install -y -q yum-utils
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

    info "Installation de Docker Engine + Compose plugin..."
    $pkg_manager install -y -q \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    success "Docker installé via le dépôt officiel."
}

# ── 1. Prérequis ─────────────────────────────────────────────────────────────
# (Les vérifications finales sont déjà effectuées par install_dependencies)
check_prerequisites() {
    : # no-op — couvert par install_dependencies
}

# ── 2. Chargement du .env ────────────────────────────────────────────────────
load_dotenv_file() {
    local env_file="$1"
    local line key value

    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"

        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        if [[ "$line" != *=* ]]; then
            error "Entrée invalide dans ${env_file} : ${line}"
        fi

        key="${line%%=*}"
        value="${line#*=}"

        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"

        if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            error "Nom de variable invalide dans ${env_file} : ${key}"
        fi

        if [[ "$value" =~ ^".*"$ || "$value" =~ ^'.*'$ ]]; then
            value="${value:1:${#value}-2}"
        fi

        export "$key=$value"
    done < "$env_file"
}

load_env() {
    step "Chargement de la configuration"

    if [ ! -f .env ]; then
        cp .env.example .env
        warn ".env créé depuis .env.example"
        error "Veuillez remplir le fichier .env, puis relancez : bash setup.sh"
    fi

    load_dotenv_file .env

    local missing=()
    [[ -z "${MATRIX_DOMAIN:-}"      ]] && missing+=("MATRIX_DOMAIN")
    [[ -z "${MATRIX_SERVER_NAME:-}" ]] && missing+=("MATRIX_SERVER_NAME")
    [[ -z "${POSTGRES_PASSWORD:-}"  ]] && missing+=("POSTGRES_PASSWORD")

    # Détection du mode reverse proxy externe (ex: REVERSE_PROXY=traefik)
    export REVERSE_PROXY="${REVERSE_PROXY:-}"
    TRAEFIK_MODE=false
    if [[ "${REVERSE_PROXY,,}" == "traefik" ]]; then
        TRAEFIK_MODE=true
        info "Mode TRAEFIK détecté — nginx et certbot désactivés, SSL géré par Traefik."
    else
        [[ -z "${LETSENCRYPT_EMAIL:-}" ]] && missing+=("LETSENCRYPT_EMAIL")
    fi
    export TRAEFIK_MODE

    if [ ${#missing[@]} -gt 0 ]; then
        error "Variables manquantes dans .env : ${missing[*]}"
    fi

    # Valeurs par défaut exportées pour docker compose
    export POSTGRES_USER="${POSTGRES_USER:-synapse}"
    export POSTGRES_DB="${POSTGRES_DB:-synapse}"
    export SYNAPSE_ALLOW_REGISTRATION="${SYNAPSE_ALLOW_REGISTRATION:-false}"
    export HTTP_PORT="${HTTP_PORT:-80}"
    export HTTPS_PORT="${HTTPS_PORT:-443}"
    export FED_PORT="${FED_PORT:-8448}"

    # Détection mode local (domaine = localhost ou 127.x.x.x)
    LOCAL_MODE=false
    if [[ "${MATRIX_DOMAIN}" == "localhost" || "${MATRIX_DOMAIN}" =~ ^127\. || "${MATRIX_DOMAIN}" =~ \.localhost$ ]]; then
        LOCAL_MODE=true
        warn "Mode LOCAL détecté (${MATRIX_DOMAIN}) — SSL et certbot désactivés."
    fi
    export LOCAL_MODE

    # Element Call (LiveKit) — optionnel
    export LIVEKIT_API_KEY="${LIVEKIT_API_KEY:-}"
    export LIVEKIT_API_SECRET="${LIVEKIT_API_SECRET:-}"
    export LIVEKIT_URL="${LIVEKIT_URL:-}"
    if [[ -n "${LIVEKIT_API_KEY}" && -n "${LIVEKIT_API_SECRET}" && -n "${LIVEKIT_URL}" ]]; then
        info "Element Call (LiveKit) activé."
        if [[ "${TRAEFIK_MODE}" == "true" ]]; then
            export LIVEKIT_JWT_URL="https://${MATRIX_DOMAIN}/livekit/jwt"
        elif [[ "${LOCAL_MODE}" == "true" ]]; then
            export LIVEKIT_JWT_URL="http://${MATRIX_DOMAIN}:${HTTP_PORT}/livekit/jwt"
        else
            export LIVEKIT_JWT_URL="https://${MATRIX_DOMAIN}/livekit/jwt"
        fi
    else
        export LIVEKIT_JWT_URL=""
    fi

    success "Domaine Matrix      : ${MATRIX_DOMAIN}"
    success "Nom du serveur      : ${MATRIX_SERVER_NAME}"
    if [[ "${TRAEFIK_MODE}" == "true" ]]; then
        success "Reverse proxy       : Traefik (SSL automatique)"
    elif [ "${LOCAL_MODE}" = "false" ]; then
        success "Email Let's Encrypt : ${LETSENCRYPT_EMAIL}"
    fi
    success "Port HTTP           : ${HTTP_PORT}"
}

# ── 3. Répertoires ───────────────────────────────────────────────────────────
create_directories() {
    step "Création des répertoires de données"
    mkdir -p \
        data/synapse \
        data/postgres \
        data/certbot/conf \
        data/certbot/www \
        data/livekit \
        nginx/conf.d
    success "Répertoires créés dans ./data/"
}

# ── 4. Config nginx HTTP (pour certbot) ──────────────────────────────────────
setup_nginx_init() {
    if [[ "${TRAEFIK_MODE}" == "true" ]]; then
        info "Mode Traefik — configuration nginx non nécessaire."
        return
    fi
    step "Configuration nginx — mode initialisation (HTTP)"
    sed "s|MATRIX_DOMAIN_PLACEHOLDER|${MATRIX_DOMAIN}|g" \
        nginx/matrix-init.conf.template > nginx/conf.d/matrix.conf
    success "nginx/conf.d/matrix.conf (HTTP only) généré."
}

# ── 5. Config Synapse ────────────────────────────────────────────────────────
generate_synapse_config() {
    step "Génération de la configuration Synapse"

    if [ -f "data/synapse/homeserver.yaml" ]; then
        warn "data/synapse/homeserver.yaml existe déjà — mise à jour appliquée."
    else
        info "Génération du homeserver.yaml initial (Synapse generate)..."
        docker run --rm \
            -v "$(pwd)/data/synapse:/data" \
            -e "SYNAPSE_SERVER_NAME=${MATRIX_SERVER_NAME}" \
            -e "SYNAPSE_REPORT_STATS=no" \
            matrixdotorg/synapse:latest generate
    fi

    info "Application de la configuration PostgreSQL et des options de sécurité..."
    # On utilise Python + PyYAML (disponibles dans l'image Synapse) pour modifier
    # homeserver.yaml sans casser le format YAML.
    # Le script Python est écrit dans un fichier temporaire puis monté dans le
    # conteneur — évite le problème du heredoc avec docker run (stdin non transmis).
    local py_script
    py_script=$(mktemp /tmp/synapse_configure_XXXXXX.py)
    cat > "${py_script}" << 'PYEOF'
import yaml
import os

cfg_path = '/data/homeserver.yaml'

with open(cfg_path, 'r') as f:
    config = yaml.safe_load(f)

# Base de données PostgreSQL (requis : encodage C, voir POSTGRES_INITDB_ARGS)
config['database'] = {
    'name': 'psycopg2',
    'args': {
        'user':     os.environ['POSTGRES_USER'],
        'password': os.environ['POSTGRES_PASSWORD'],
        'database': os.environ['POSTGRES_DB'],
        'host':     'postgres',
        'cp_min':   5,
        'cp_max':   10,
    }
}

# URL publique (utilisée par les clients pour se connecter)
local_mode = os.environ.get('LOCAL_MODE', 'false').lower() == 'true'
traefik_mode = os.environ.get('TRAEFIK_MODE', 'false').lower() == 'true'
http_port  = os.environ.get('HTTP_PORT', '80')
if local_mode:
    port_suffix = '' if http_port == '80' else ':' + http_port
    config['public_baseurl'] = 'http://' + os.environ['MATRIX_DOMAIN'] + port_suffix + '/'
else:
    config['public_baseurl'] = 'https://' + os.environ['MATRIX_DOMAIN'] + '/'

# Avec Traefik ou en production, Synapse sert lui-même les endpoints .well-known
if traefik_mode or not local_mode:
    config['serve_server_wellknown'] = True

# Inscription publique
config['enable_registration'] = (
    os.environ.get('ALLOW_REGISTRATION', 'false').lower() == 'true'
)

# Sécurité : restreindre l'accès à l'annuaire public sans authentification
config['allow_public_rooms_over_federation'] = False
config['allow_public_rooms_without_auth']    = False

# Element Call (VoIP/vidéo via MatrixRTC + LiveKit)
livekit_url = os.environ.get('LIVEKIT_JWT_URL', '')
if livekit_url:
    # Flag expérimental : active l'endpoint /_matrix/client/unstable/org.matrix.msc4143/rtc/transports
    config.setdefault('experimental_features', {})
    config['experimental_features']['msc4143_enabled'] = True
    # Transport LiveKit effectif
    config['matrix_rtc'] = {
        'transports': [{
            'type': 'livekit',
            'livekit_service_url': livekit_url,
        }]
    }
    # MSC4140 : Delayed events (nécessaire pour la signalisation Element Call)
    config['max_event_delay_duration'] = '24h'

with open(cfg_path, 'w') as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

print('homeserver.yaml mis à jour : PostgreSQL, URL publique, options de sécurité.')
PYEOF

    # --entrypoint python3 : contourne l'entrypoint /start.py de l'image Synapse
    # qui intercepterait "python3" comme un mode d'exécution inconnu.
    docker run --rm \
        --entrypoint python3 \
        -v "$(pwd)/data/synapse:/data" \
        -v "${py_script}:/tmp/configure.py:ro" \
        -e "POSTGRES_USER=${POSTGRES_USER}" \
        -e "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
        -e "POSTGRES_DB=${POSTGRES_DB}" \
        -e "MATRIX_DOMAIN=${MATRIX_DOMAIN}" \
        -e "ALLOW_REGISTRATION=${SYNAPSE_ALLOW_REGISTRATION}" \
        -e "LOCAL_MODE=${LOCAL_MODE}" \
        -e "HTTP_PORT=${HTTP_PORT}" \
        -e "TRAEFIK_MODE=${TRAEFIK_MODE}" \
        -e "LIVEKIT_JWT_URL=${LIVEKIT_JWT_URL}" \
        matrixdotorg/synapse:latest /tmp/configure.py

    rm -f "${py_script}"

    success "homeserver.yaml prêt dans data/synapse/"
}

# ── 5b. Config LiveKit (optionnel — Element Call) ────────────────────────────
generate_livekit_config() {
    if [[ -z "${LIVEKIT_API_KEY}" ]]; then
        return
    fi

    step "Génération de la configuration LiveKit"

    cat > data/livekit/livekit.yaml << EOF
port: 7880
rtc:
  port_range_start: 50000
  port_range_end: 60000
  udp_port: 7882
  tcp_port: 7881
keys:
  ${LIVEKIT_API_KEY}: ${LIVEKIT_API_SECRET}
EOF

    success "data/livekit/livekit.yaml généré."
}

# ── 6. Démarrage nginx (HTTP) ─────────────────────────────────────────────────
start_nginx() {
    if [[ "${TRAEFIK_MODE}" == "true" ]]; then
        info "Mode Traefik — démarrage nginx non nécessaire."
        return
    fi
    step "Démarrage de nginx (HTTP)"
    # Seul nginx démarre ici pour le challenge ACME (inutile en mode local).
    compose up -d nginx
    sleep 3
    success "Nginx démarré sur le port ${HTTP_PORT}."
}

# ── 7. Certificat SSL Let's Encrypt ──────────────────────────────────────────
obtain_ssl_certificate() {
    if [[ "${TRAEFIK_MODE}" == "true" ]]; then
        info "Mode Traefik — certificat SSL géré automatiquement par Traefik."
        return
    fi

    step "Certificat SSL Let's Encrypt"

    if [ "${LOCAL_MODE}" = "true" ]; then
        warn "Mode local — étape SSL ignorée."
        return
    fi

    if [ -f "data/certbot/conf/live/${MATRIX_DOMAIN}/fullchain.pem" ]; then
        warn "Certificat déjà présent pour ${MATRIX_DOMAIN} — étape ignorée."
        return
    fi

    info "Obtention du certificat pour ${MATRIX_DOMAIN}..."
    info "⚠  Le port 80 doit être ouvert et accessible depuis Internet."

    compose run --rm certbot certonly \
        --webroot \
        --webroot-path=/var/www/certbot \
        --email "${LETSENCRYPT_EMAIL}" \
        --agree-tos \
        --no-eff-email \
        -d "${MATRIX_DOMAIN}"

    success "Certificat SSL obtenu."
}

# ── 8. Config nginx HTTPS ─────────────────────────────────────────────────────
setup_nginx_https() {
    if [[ "${TRAEFIK_MODE}" == "true" ]]; then
        info "Mode Traefik — configuration nginx HTTPS non nécessaire."
        return
    fi
    if [ "${LOCAL_MODE}" = "true" ]; then
        step "Configuration nginx — mode local (HTTP)"
        sed "s|MATRIX_DOMAIN_PLACEHOLDER|${MATRIX_DOMAIN}|g" \
            nginx/matrix-local.conf.template > nginx/conf.d/matrix.conf
        success "nginx/conf.d/matrix.conf (HTTP local) généré."
        return
    fi
    step "Configuration nginx — mode production (HTTPS)"
    sed "s|MATRIX_DOMAIN_PLACEHOLDER|${MATRIX_DOMAIN}|g" \
        nginx/matrix.conf.template > nginx/conf.d/matrix.conf
    success "nginx/conf.d/matrix.conf (HTTPS) généré."
}

# ── 9. Démarrage de tous les services ────────────────────────────────────────
start_all_services() {
    step "Démarrage de tous les services"

    local profiles=()
    if [[ -n "${LIVEKIT_API_KEY}" ]]; then
        profiles+=("--profile" "calls")
    fi

    compose "${profiles[@]}" up -d

    info "Attente du démarrage de Synapse (60 secondes max)..."
    local retries=12
    while [ $retries -gt 0 ]; do
        if compose exec -T synapse curl -fSs http://localhost:8008/health >/dev/null 2>&1; then
            break
        fi
        sleep 5
        retries=$(( retries - 1 ))
    done

    if [[ "${TRAEFIK_MODE}" != "true" ]]; then
        compose exec nginx nginx -s reload
    fi
    success "Tous les services sont opérationnels."
}

# ── 10. Compte administrateur ────────────────────────────────────────────────
create_admin_user() {
    step "Compte administrateur Matrix"
    echo ""
    read -r -p "  Créer un compte administrateur maintenant ? [o/N] " answer
    if [[ "${answer,,}" == "o" ]]; then
        read -r -p "  Nom d'utilisateur : " admin_user
        compose exec synapse \
            register_new_matrix_user \
            -c /data/homeserver.yaml \
            -a \
            -u "${admin_user}" \
            http://localhost:8008
    else
        warn "Vous pourrez créer un admin plus tard avec : make admin"
    fi
}

# ==============================================================================
# POINT D'ENTRÉE
# ==============================================================================
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗"
    echo -e "║     Installation du serveur Matrix Synapse       ║"
    echo -e "╚══════════════════════════════════════════════════╝${NC}"
    echo ""

    install_dependencies
    load_env
    create_directories
    setup_nginx_init
    generate_synapse_config
    generate_livekit_config
    start_nginx
    obtain_ssl_certificate
    setup_nginx_https
    start_all_services
    create_admin_user

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗"
    echo -e "║   Serveur Matrix opérationnel !                              ║"
    echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    if [ "${LOCAL_MODE}" = "true" ]; then
        local port_suffix=""
        [ "${HTTP_PORT}" != "80" ] && port_suffix=":${HTTP_PORT}"
        echo -e "  Serveur HTTP   : ${BOLD}http://${MATRIX_DOMAIN}${port_suffix}${NC}"
        echo -e "  IDs Matrix     : ${BOLD}@utilisateur:${MATRIX_SERVER_NAME}${NC}"
        echo -e "  API Synapse    : http://${MATRIX_DOMAIN}${port_suffix}/_matrix/client/versions"
    else
        echo -e "  Serveur HTTPS  : ${BOLD}https://${MATRIX_DOMAIN}${NC}"
        echo -e "  IDs Matrix     : ${BOLD}@utilisateur:${MATRIX_SERVER_NAME}${NC}"
        echo -e "  Admin API      : https://${MATRIX_DOMAIN}/_synapse/admin/v1"
        if [[ "${TRAEFIK_MODE}" == "true" ]]; then
            echo -e "  SSL            : ${BOLD}Géré par Traefik${NC}"
        fi
    fi
    echo ""
    echo -e "  Clients compatibles :"
    echo -e "    • Element Web  → https://app.element.io"
    echo -e "    • FluffyChat, Cinny, SchildiChat, Hydrogen..."
    echo ""
    echo -e "  Commandes utiles :"
    echo -e "    make logs         — Suivre les logs en temps réel"
    echo -e "    make status       — État des conteneurs"
    echo -e "    make admin        — Créer un administrateur"
    echo -e "    make backup       — Sauvegarder BDD + données Synapse"
    if [[ "${TRAEFIK_MODE}" != "true" ]]; then
        echo -e "    make renew-certs  — Renouveler le certificat SSL"
    fi
    echo ""
}

main "$@"
