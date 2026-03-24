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

# ── 0. Installation des dépendances ──────────────────────────────────────────
install_dependencies() {
    step "Installation des dépendances (Docker + Compose)"

    # Ce script nécessite les droits root pour installer des paquets
    if [ "$(id -u)" -ne 0 ]; then
        error "Ce script doit être exécuté en root ou avec sudo."
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
    docker compose version >/dev/null 2>&1 \
        || error "Docker Compose V2 introuvable après installation. Installez le plugin : https://docs.docker.com/compose/install/"

    # S'assurer que le démon Docker tourne
    if ! docker info >/dev/null 2>&1; then
        info "Démarrage du service Docker..."
        systemctl enable --now docker
    fi

    success "Docker       : $(docker --version | awk '{print $3}' | tr -d ',')"
    success "Compose      : $(docker compose version --short)"
}

_install_docker_apt() {
    # ── Debian / Ubuntu ──────────────────────────────────────────────────────
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        success "Docker et Compose déjà installés — aucune action nécessaire."
        return
    fi

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
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        success "Docker et Compose déjà installés — aucune action nécessaire."
        return
    fi

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
load_env() {
    step "Chargement de la configuration"

    if [ ! -f .env ]; then
        cp .env.example .env
        warn ".env créé depuis .env.example"
        error "Veuillez remplir le fichier .env, puis relancez : bash setup.sh"
    fi

    # shellcheck disable=SC1091
    source .env

    local missing=()
    [[ -z "${MATRIX_DOMAIN:-}"      ]] && missing+=("MATRIX_DOMAIN")
    [[ -z "${MATRIX_SERVER_NAME:-}" ]] && missing+=("MATRIX_SERVER_NAME")
    [[ -z "${POSTGRES_PASSWORD:-}"  ]] && missing+=("POSTGRES_PASSWORD")
    [[ -z "${LETSENCRYPT_EMAIL:-}"  ]] && missing+=("LETSENCRYPT_EMAIL")

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
    if [[ "${MATRIX_DOMAIN}" == "localhost" || "${MATRIX_DOMAIN}" =~ ^127\. ]]; then
        LOCAL_MODE=true
        warn "Mode LOCAL détecté (${MATRIX_DOMAIN}) — SSL et certbot désactivés."
    fi
    export LOCAL_MODE

    success "Domaine Matrix      : ${MATRIX_DOMAIN}"
    success "Nom du serveur      : ${MATRIX_SERVER_NAME}"
    if [ "${LOCAL_MODE}" = "false" ]; then
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
        nginx/conf.d
    success "Répertoires créés dans ./data/"
}

# ── 4. Config nginx HTTP (pour certbot) ──────────────────────────────────────
setup_nginx_init() {
    step "Configuration nginx — mode initialisation (HTTP)"
    sed "s|MATRIX_DOMAIN_PLACEHOLDER|${MATRIX_DOMAIN}|g" \
        nginx/matrix-init.conf.template > nginx/conf.d/matrix.conf
    success "nginx/conf.d/matrix.conf (HTTP only) généré."
}

# ── 5. Config Synapse ────────────────────────────────────────────────────────
generate_synapse_config() {
    step "Génération de la configuration Synapse"

    if [ -f "data/synapse/homeserver.yaml" ]; then
        warn "data/synapse/homeserver.yaml existe déjà — étape ignorée."
        return
    fi

    info "Génération du homeserver.yaml initial (Synapse generate)..."
    docker run --rm \
        -v "$(pwd)/data/synapse:/data" \
        -e "SYNAPSE_SERVER_NAME=${MATRIX_SERVER_NAME}" \
        -e "SYNAPSE_REPORT_STATS=no" \
        matrixdotorg/synapse:latest generate

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
http_port  = os.environ.get('HTTP_PORT', '80')
if local_mode:
    port_suffix = '' if http_port == '80' else ':' + http_port
    config['public_baseurl'] = 'http://' + os.environ['MATRIX_DOMAIN'] + port_suffix + '/'
else:
    config['public_baseurl'] = 'https://' + os.environ['MATRIX_DOMAIN'] + '/'
# Inscription publique
config['enable_registration'] = (
    os.environ.get('ALLOW_REGISTRATION', 'false').lower() == 'true'
)

# Sécurité : restreindre l'accès à l'annuaire public sans authentification
config['allow_public_rooms_over_federation'] = False
config['allow_public_rooms_without_auth']    = False

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
        matrixdotorg/synapse:latest /tmp/configure.py

    rm -f "${py_script}"

    success "homeserver.yaml prêt dans data/synapse/"
}

# ── 6. Démarrage nginx (HTTP) ─────────────────────────────────────────────────
start_nginx() {
    step "Démarrage de nginx (HTTP)"
    # Seul nginx démarre ici pour le challenge ACME (inutile en mode local).
    docker compose up -d nginx
    sleep 3
    success "Nginx démarré sur le port ${HTTP_PORT}."
}

# ── 7. Certificat SSL Let's Encrypt ──────────────────────────────────────────
obtain_ssl_certificate() {
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

    docker compose run --rm certbot certonly \
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
    if [ "${LOCAL_MODE}" = "true" ]; then
        warn "Mode local — config HTTPS ignorée, le serveur reste en HTTP."
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
    docker compose up -d

    info "Attente du démarrage de Synapse (60 secondes max)..."
    local retries=12
    while [ $retries -gt 0 ]; do
        if docker compose exec -T synapse curl -fSs http://localhost:8008/health >/dev/null 2>&1; then
            break
        fi
        sleep 5
        retries=$(( retries - 1 ))
    done

    docker compose exec nginx nginx -s reload
    success "Tous les services sont opérationnels."
}

# ── 10. Compte administrateur ────────────────────────────────────────────────
create_admin_user() {
    step "Compte administrateur Matrix"
    echo ""
    read -r -p "  Créer un compte administrateur maintenant ? [o/N] " answer
    if [[ "${answer,,}" == "o" ]]; then
        read -r -p "  Nom d'utilisateur : " admin_user
        docker compose exec synapse \
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
    echo -e "    make renew-certs  — Renouveler le certificat SSL"
    echo ""
}

main "$@"
