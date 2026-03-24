#!/usr/bin/env bash
# ==============================================================================
# setup.sh — Configuration initiale du serveur Matrix Synapse
#
# Usage : bash setup.sh
#
# Ce script effectue dans l'ordre :
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

# ── 1. Prérequis ─────────────────────────────────────────────────────────────
check_prerequisites() {
    step "Vérification des prérequis"
    command -v docker >/dev/null 2>&1 \
        || error "Docker n'est pas installé. Voir : https://docs.docker.com/engine/install/"
    docker compose version >/dev/null 2>&1 \
        || error "Docker Compose V2 n'est pas disponible (plugin 'compose' manquant)."
    docker info >/dev/null 2>&1 \
        || error "Le démon Docker n'est pas en cours d'exécution."

    success "Docker       : $(docker --version | awk '{print $3}' | tr -d ',')"
    success "Compose      : $(docker compose version --short)"
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

    success "Domaine Matrix      : ${MATRIX_DOMAIN}"
    success "Nom du serveur      : ${MATRIX_SERVER_NAME}"
    success "Email Let's Encrypt : ${LETSENCRYPT_EMAIL}"
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
    # Les secrets sont passés via des variables d'environnement Docker (pas dans le script).
    docker run --rm \
        -v "$(pwd)/data/synapse:/data" \
        -e "POSTGRES_USER=${POSTGRES_USER}" \
        -e "POSTGRES_PASSWORD=${POSTGRES_PASSWORD}" \
        -e "POSTGRES_DB=${POSTGRES_DB}" \
        -e "MATRIX_DOMAIN=${MATRIX_DOMAIN}" \
        -e "ALLOW_REGISTRATION=${SYNAPSE_ALLOW_REGISTRATION}" \
        matrixdotorg/synapse:latest python3 - <<'PYEOF'
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

    success "homeserver.yaml prêt dans data/synapse/"
}

# ── 6. Démarrage nginx (HTTP) ─────────────────────────────────────────────────
start_nginx() {
    step "Démarrage de nginx (HTTP)"
    # Seul nginx démarre ici (pas de depends_on sur synapse), ce qui suffit
    # pour le challenge ACME webroot.
    docker compose up -d nginx
    sleep 3
    success "Nginx démarré."
}

# ── 7. Certificat SSL Let's Encrypt ──────────────────────────────────────────
obtain_ssl_certificate() {
    step "Certificat SSL Let's Encrypt"

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

    check_prerequisites
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
    echo -e "  Serveur HTTPS  : ${BOLD}https://${MATRIX_DOMAIN}${NC}"
    echo -e "  IDs Matrix     : ${BOLD}@utilisateur:${MATRIX_SERVER_NAME}${NC}"
    echo -e "  Admin API      : https://${MATRIX_DOMAIN}/_synapse/admin/v1"
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
