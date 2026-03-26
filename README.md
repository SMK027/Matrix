# Serveur Matrix Synapse — Docker

Déploiement clé en main d'un serveur [Matrix](https://matrix.org/) auto-hébergé basé sur **Synapse**, avec **PostgreSQL** comme base de données.

Trois modes de déploiement sont supportés :

| Mode | Reverse proxy | SSL | Cas d'usage |
|------|---------------|-----|-------------|
| **Traefik** | Traefik v3 (externe) | Automatique via Traefik | VPS avec Traefik existant |
| **Autonome** | Nginx (inclus) | Let's Encrypt / Certbot | Serveur dédié |
| **Local** | Nginx (inclus) | Aucun | Développement / tests |

---

## Table des matières

- [Prérequis](#prérequis)
- [Installation rapide](#installation-rapide)
- [Variables d'environnement](#variables-denvironnement)
- [Modes de déploiement](#modes-de-déploiement)
- [Commandes utiles (Makefile)](#commandes-utiles)
- [Gestion des utilisateurs](#gestion-des-utilisateurs)
- [Inscription publique](#activer-linscription-publique)
- [Fédération](#fédération)
- [Sauvegardes et restauration](#sauvegardes)
- [Délégation de domaine](#délégation-de-domaine-avancé)
- [Architecture du projet](#architecture-du-projet)
- [Détail des fichiers](#détail-des-fichiers)
- [Réseau et ports](#réseau-et-ports)
- [Configuration Synapse (homeserver.yaml)](#configuration-synapse)
- [Mise à jour](#mise-à-jour)
- [Dépannage](#dépannage)

---

## Prérequis

- **Linux** (Debian, Ubuntu, CentOS, Fedora, Rocky, AlmaLinux)
- **Docker** et **Docker Compose** (installés automatiquement par `setup.sh` si absents)
- Un **nom de domaine** pointant vers le serveur (ex : `matrix.mondomaine.fr`)
- **Port 443** accessible depuis Internet (géré par Traefik ou Nginx selon le mode)

### Prérequis supplémentaires par mode

| Mode | Prérequis |
|------|-----------|
| **Traefik** | Traefik v3 en place avec un réseau Docker `proxy` et un certresolver nommé `le` |
| **Autonome** | Ports 80, 443 et 8448 libres sur le serveur |
| **Local** | Aucun prérequis réseau |

---

## Installation rapide

### 1. Cloner le dépôt

```bash
git clone https://github.com/SMK027/Matrix.git
cd Matrix
```

### 2. Configurer le `.env`

```bash
cp .env.example .env
nano .env
```

### 3. Lancer l'installation

```bash
sudo bash setup.sh
```

Le script effectue automatiquement les étapes suivantes :

| Étape | Description | Mode Traefik | Mode Autonome | Mode Local |
|-------|-------------|:------------:|:--------------:|:----------:|
| 0 | Installation de Docker + Compose | ✔ | ✔ | ✔ |
| 1 | Validation du fichier `.env` | ✔ | ✔ | ✔ |
| 2 | Création des répertoires `data/` | ✔ | ✔ | ✔ |
| 3 | Configuration nginx HTTP (challenge ACME) | — | ✔ | — |
| 4 | Génération de `homeserver.yaml` (Synapse + PostgreSQL) | ✔ | ✔ | ✔ |
| 5 | Démarrage nginx HTTP | — | ✔ | — |
| 6 | Obtention du certificat SSL (Let's Encrypt) | — | ✔ | — |
| 7 | Configuration nginx HTTPS | — | ✔ | ✔ (HTTP) |
| 8 | Démarrage de tous les services | ✔ | ✔ | ✔ |
| 9 | Création optionnelle d'un administrateur | ✔ | ✔ | ✔ |

> **Note** : en mode Traefik, les étapes nginx/certbot/SSL sont automatiquement ignorées.

---

## Variables d'environnement

Toutes les variables sont définies dans le fichier `.env` (copié depuis `.env.example`).

### Variables obligatoires

| Variable | Description | Exemple |
|----------|-------------|---------|
| `MATRIX_DOMAIN` | Domaine complet du serveur (DNS A record) | `matrix.mondomaine.fr` |
| `MATRIX_SERVER_NAME` | Nom du serveur pour les IDs utilisateurs (`@user:SERVER_NAME`) | `matrix.mondomaine.fr` |
| `POSTGRES_PASSWORD` | Mot de passe de la base PostgreSQL | `Un_Mot_De_Passe_Fort` |

### Variables optionnelles

| Variable | Défaut | Description |
|----------|--------|-------------|
| `POSTGRES_USER` | `synapse` | Utilisateur PostgreSQL |
| `POSTGRES_DB` | `synapse` | Nom de la base de données |
| `LETSENCRYPT_EMAIL` | — | Email pour Let's Encrypt (requis sauf mode Traefik) |
| `REVERSE_PROXY` | — | Mettre `traefik` pour activer le mode Traefik |
| `SYNAPSE_ALLOW_REGISTRATION` | `false` | Inscription publique initiale (`true` / `false`) |
| `HTTP_PORT` | `80` | Port HTTP de nginx |
| `HTTPS_PORT` | `443` | Port HTTPS de nginx |
| `FED_PORT` | `8448` | Port de fédération Matrix (nginx) |

> **⚠️ Mot de passe PostgreSQL** : utilisez uniquement des caractères alphanumériques. Évitez `$`, `#`, `!`, `'`, `"` qui provoquent des erreurs d'échappement YAML.
>
> **⚠️ Important** : le mot de passe PostgreSQL est fixé lors de la première initialisation de la base. Si vous le changez après le premier démarrage, vous devez supprimer le volume de données : `docker compose down && sudo rm -rf data/postgres && docker compose up -d`.

---

## Modes de déploiement

### Mode Traefik (VPS avec reverse proxy existant)

Configuration `.env` :

```dotenv
MATRIX_DOMAIN=matrix.mondomaine.fr
MATRIX_SERVER_NAME=matrix.mondomaine.fr
POSTGRES_PASSWORD=MotDePasse_Fort_42
REVERSE_PROXY=traefik
```

Fonctionnement :
- Synapse est exposé sur le port **8008** (interne Docker uniquement, pas de port publié sur l'hôte)
- Les **labels Traefik** sur le conteneur `synapse` configurent automatiquement le routage :
  - Routeur `matrix` sur l'entrypoint `websecure` (port 443)
  - Règle `Host(matrix.mondomaine.fr)`
  - TLS via le certresolver `le`
  - Loadbalancer vers le port 8008 du conteneur
- Le conteneur est connecté au réseau Docker **`proxy`** (externe, partagé avec Traefik)
- Nginx et Certbot ne sont pas démarrés (profil `local` non activé)
- Synapse sert lui-même les endpoints `.well-known` (`serve_server_wellknown: true`)

### Mode autonome (serveur dédié)

Configuration `.env` :

```dotenv
MATRIX_DOMAIN=matrix.mondomaine.fr
MATRIX_SERVER_NAME=matrix.mondomaine.fr
POSTGRES_PASSWORD=MotDePasse_Fort_42
LETSENCRYPT_EMAIL=admin@mondomaine.fr
```

Fonctionnement :
- **Nginx** fait office de reverse proxy (ports 80, 443, 8448)
- **Certbot** obtient un certificat Let's Encrypt via challenge HTTP-01
- Nginx gère la terminaison TLS (TLSv1.2/1.3), HSTS, et les en-têtes de sécurité
- Le port **8448** est dédié à la fédération Matrix
- Nginx sert les endpoints `.well-known/matrix/server` et `.well-known/matrix/client`
- Redirection automatique HTTP → HTTPS

### Mode local (développement)

Configuration `.env` :

```dotenv
MATRIX_DOMAIN=localhost
MATRIX_SERVER_NAME=localhost
POSTGRES_PASSWORD=dev123
HTTP_PORT=8090
```

Démarrage avec le fichier Compose de développement :

```bash
docker compose -f docker-compose.dev.yml up -d
```

Fonctionnement :
- Pas de SSL, pas de Traefik
- Nginx en HTTP sur le port configuré (ex : 8090)
- Tous les services sur un réseau bridge interne `matrix-net`
- Accès via `http://localhost:8090/_matrix/client/versions`

---

## Commandes utiles

Toutes les opérations courantes sont accessibles via le `Makefile` :

| Commande | Description |
|----------|-------------|
| `make setup` | Lancer l'installation complète (`setup.sh`) |
| `make up` | Démarrer tous les conteneurs |
| `make down` | Arrêter tous les conteneurs |
| `make restart` | Redémarrer les conteneurs |
| `make logs` | Suivre les logs en temps réel (Ctrl+C pour quitter) |
| `make status` | État des conteneurs |
| `make admin` | Créer un compte administrateur (interactif) |
| `make backup` | Sauvegarder la BDD et la config Synapse dans `backups/` |
| `make renew-certs` | Renouveler le certificat SSL (mode autonome uniquement) |
| `make shell-synapse` | Ouvrir un shell bash dans le conteneur Synapse |
| `make shell-postgres` | Ouvrir un shell psql dans PostgreSQL |

> En mode Traefik, `make renew-certs` affiche un message informatif car les certificats sont gérés automatiquement par Traefik.

---

## Gestion des utilisateurs

### Créer un administrateur

```bash
make admin
```

Le script demande le nom d'utilisateur et le mot de passe de manière interactive.

Ou manuellement :

```bash
docker compose exec synapse register_new_matrix_user \
  -c /data/homeserver.yaml \
  -a -u mon_admin \
  http://localhost:8008
```

Le flag `-a` accorde les droits administrateur.

### Créer un utilisateur standard

```bash
docker compose exec synapse register_new_matrix_user \
  -c /data/homeserver.yaml \
  -u mon_utilisateur \
  http://localhost:8008
```

Le script demande interactivement un mot de passe et s'il doit être administrateur.

### Lister les utilisateurs existants

Via l'API admin (nécessite un access token admin) :

```bash
curl -s -H "Authorization: Bearer VOTRE_TOKEN_ADMIN" \
  http://localhost:8008/_synapse/admin/v2/users | python3 -m json.tool
```

Pour obtenir un access token, connectez-vous via un client Matrix (Element Web, etc.) et récupérez-le dans les paramètres du client (Paramètres → Aide & À propos → Access Token).

---

## Activer l'inscription publique

Par défaut, seul un administrateur peut créer des comptes (via `make admin`).
Trois options permettent aux utilisateurs de s'inscrire eux-mêmes.

### Option 1 — Inscription avec captcha (recommandé)

Protège contre le spam en exigeant un reCAPTCHA lors de l'inscription.

1. **Créez des clés reCAPTCHA** sur [Google reCAPTCHA Admin](https://www.google.com/recaptcha/admin) :
   - Type : **reCAPTCHA v2 — case à cocher « I'm not a robot »** (Synapse ne supporte pas v3)
   - Domaines : ajoutez le domaine de votre serveur et les domaines des clients web

2. **Configuration des domaines reCAPTCHA** : le reCAPTCHA est validé côté client (navigateur), donc le domaine vérifié est celui de l'application web utilisée par l'utilisateur, pas celui de votre serveur Matrix. Ajoutez tous les domaines clients autorisés :

   | Client web | Domaine à ajouter |
   |------------|-------------------|
   | Element Web | `app.element.io` |
   | Cinny | `app.cinny.in` |
   | FluffyChat Web | `fluffychat.im` |
   | SchildiChat Web | `app.schildi.chat` |
   | Hydrogen | `hydrogen.element.io` |
   | Votre serveur | `matrix.mondomaine.fr` |

   > **Astuce** : vous pouvez aussi décocher la case « Validation du domaine » dans les paramètres reCAPTCHA pour accepter tous les domaines.

3. **Ajoutez dans `data/synapse/homeserver.yaml`** :

   ```yaml
   enable_registration: true
   enable_registration_captcha: true
   recaptcha_public_key: "VOTRE_CLE_PUBLIQUE"
   recaptcha_private_key: "VOTRE_CLE_PRIVEE"
   ```

4. **Redémarrez Synapse** :

   ```bash
   docker compose restart synapse
   ```

### Option 2 — Inscription par token

Les utilisateurs doivent fournir un token d'invitation pour s'inscrire. Idéal pour un serveur semi-privé.

1. Ajoutez dans `data/synapse/homeserver.yaml` :

   ```yaml
   enable_registration: true
   registration_requires_token: true
   ```

2. Redémarrez Synapse :

   ```bash
   docker compose restart synapse
   ```

3. Créez un token via l'API admin (remplacez `VOTRE_TOKEN_ADMIN` par un access token admin) :

   ```bash
   curl -s -X POST \
     -H "Authorization: Bearer VOTRE_TOKEN_ADMIN" \
     -H "Content-Type: application/json" \
     http://localhost:8008/_synapse/admin/v1/registration_tokens/new \
     -d '{"uses_allowed": 10}'
   ```

   Distribuez le token renvoyé aux personnes autorisées à s'inscrire.

4. Pour lister les tokens existants :

   ```bash
   curl -s -H "Authorization: Bearer VOTRE_TOKEN_ADMIN" \
     http://localhost:8008/_synapse/admin/v1/registration_tokens
   ```

### Option 3 — Inscription libre sans vérification (déconseillé)

> **⚠️ Déconseillé en production** — expose le serveur au spam et aux abus.

```yaml
enable_registration: true
enable_registration_without_verification: true
```

### Compatibilité des clients

| Client | Inscription classique | Nécessite MAS |
|--------|:--------------------:|:-------------:|
| [Element Web](https://app.element.io) | ✔ | Non |
| [Element Desktop](https://element.io/download) (classique) | ✔ | Non |
| [FluffyChat](https://fluffychat.im) | ✔ | Non |
| [SchildiChat](https://schildi.chat) | ✔ | Non |
| [Cinny](https://cinny.in) | ✔ | Non |
| **Element X** (mobile) | ✘ | **Oui** |

> **Note sur Element X** : ce client exige **Matrix Authentication Service (MAS)**,
> un service d'authentification OIDC externe non inclus dans cette installation.
> Utilisez Element classique (Web ou Desktop) ou un autre client du tableau pour l'inscription et la connexion.

---

## Fédération

La fédération permet à votre serveur de communiquer avec d'autres serveurs Matrix (matrix.org, etc.).

### Vérification de la fédération

Utilisez l'outil officiel :

```
https://federationtester.matrix.org/api/report?server_name=matrix.mondomaine.fr
```

Ou en ligne de commande :

```bash
curl -s "https://federationtester.matrix.org/api/report?server_name=matrix.mondomaine.fr" \
  | python3 -m json.tool
```

### Ports requis pour la fédération

| Mode | Port | Géré par |
|------|------|----------|
| Traefik | 443 | Traefik (via `serve_server_wellknown` de Synapse) |
| Autonome | 443 + 8448 | Nginx (bloc server dédié au port 8448) |

En mode **Traefik**, la fédération passe par le port 443 grâce à l'option `serve_server_wellknown: true` de Synapse, qui expose `/.well-known/matrix/server` indiquant aux autres serveurs de se connecter sur le port 443.

En mode **autonome**, Nginx écoute aussi sur le port **8448** (port standard de fédération Matrix) et proxie les requêtes vers Synapse.

---

## Sauvegardes

```bash
make backup
```

Crée dans le dossier `backups/` :
- `db-YYYYMMDD-HHMMSS.sql.gz` — Dump PostgreSQL compressé
- `synapse-YYYYMMDD-HHMMSS.tar.gz` — Config Synapse (hors médias)

### Restauration de la base de données

```bash
gunzip -c backups/db-XXXXXXXX-XXXXXX.sql.gz | \
  docker compose exec -T postgres psql -U synapse synapse
```

### Sauvegarde des médias

Les fichiers média (images, vidéos envoyés dans les salons) sont stockés dans `data/synapse/media_store/`. Ils ne sont pas inclus dans `make backup` en raison de leur taille potentielle. Pour les sauvegarder :

```bash
tar -czf "backups/media-$(date +%Y%m%d-%H%M%S).tar.gz" data/synapse/media_store/
```

### Sauvegarde automatique (cron)

```bash
# Sauvegarde quotidienne à 3h du matin
0 3 * * * cd /chemin/vers/Matrix && make backup
```

---

## Délégation de domaine (avancé)

Pour avoir des IDs courts (`@user:mondomaine.fr` au lieu de `@user:matrix.mondomaine.fr`) :

1. Définissez dans le `.env` :
   ```dotenv
   MATRIX_DOMAIN=matrix.mondomaine.fr
   MATRIX_SERVER_NAME=mondomaine.fr
   ```

2. Sur le serveur web de `mondomaine.fr`, servez le fichier `/.well-known/matrix/server` :
   ```json
   { "m.server": "matrix.mondomaine.fr:443" }
   ```

3. Et `/.well-known/matrix/client` :
   ```json
   { "m.homeserver": { "base_url": "https://matrix.mondomaine.fr" } }
   ```

> **⚠️ Important** : le `server_name` ne peut plus être changé après la création du premier compte. Choisissez-le définitivement avant le premier déploiement.

---

## Architecture du projet

```
Matrix/
├── docker-compose.yml            # Production (Traefik ou Autonome)
├── docker-compose.dev.yml        # Développement local
├── setup.sh                      # Script d'installation automatisé
├── Makefile                      # Raccourcis de commandes courantes
├── .env.example                  # Modèle de configuration
├── .env                          # Configuration active (non versionné)
├── nginx/
│   ├── matrix.conf.template          # Template nginx HTTPS (production)
│   ├── matrix-init.conf.template     # Template nginx HTTP (challenge certbot)
│   ├── matrix-local.conf.template    # Template nginx HTTP (développement)
│   └── conf.d/
│       └── matrix.conf               # Config nginx active (générée par setup.sh)
├── data/
│   ├── synapse/
│   │   ├── homeserver.yaml           # Configuration Synapse (générée)
│   │   ├── *.signing.key             # Clé de signature du serveur
│   │   ├── *.log.config              # Configuration des logs Synapse
│   │   └── media_store/              # Fichiers média uploadés
│   ├── postgres/                     # Données PostgreSQL (volume)
│   └── certbot/
│       ├── conf/                     # Certificats Let's Encrypt
│       └── www/                      # Challenge ACME webroot
└── backups/                          # Sauvegardes (créé par make backup)
```

---

## Détail des fichiers

### docker-compose.yml (production)

Fichier Compose principal pour les modes **Traefik** et **Autonome**.

**Services** :

| Service | Image | Rôle | Réseaux |
|---------|-------|------|---------|
| `synapse` | `matrixdotorg/synapse:latest` | Homeserver Matrix | `matrix-net`, `proxy` |
| `postgres` | `postgres:16-alpine` | Base de données | `matrix-net` |
| `nginx` | `nginx:alpine` | Reverse proxy (profil `local`) | `matrix-net` |
| `certbot` | `certbot/certbot` | Certificats SSL (profil `local`) | — |

- **Synapse** : expose le port 8008 (interne), connecté aux réseaux `matrix-net` et `proxy`. Les labels Traefik sont toujours présents mais n'ont d'effet que si Traefik est actif. Healthcheck sur `/health`.
- **PostgreSQL** : initialisation automatique avec encodage UTF-8 et collation C (requis par Synapse). Healthcheck via `pg_isready`.
- **Nginx** et **Certbot** : placés sous le profil `local`, ils ne démarrent que si activés explicitement (mode autonome). Le profil est géré par `setup.sh`.

### docker-compose.dev.yml (développement)

Fichier Compose simplifié pour le développement local :
- Pas de labels Traefik, pas de réseau `proxy`
- Nginx démarre systématiquement (pas de profil)
- Certbot inclus mais non démarré par défaut
- Tous les services sur le réseau interne `matrix-net` uniquement

### setup.sh

Script d'installation automatisé (à exécuter avec `sudo`). Détecte le mode de déploiement via la variable `REVERSE_PROXY` :
- `REVERSE_PROXY=traefik` → mode Traefik (ignore nginx/certbot/SSL)
- `MATRIX_DOMAIN=localhost` → mode Local (ignore SSL)
- Sinon → mode Autonome (nginx + certbot + SSL)

La configuration Synapse est générée via un script Python exécuté dans l'image Docker Synapse elle-même (utilise PyYAML intégré), ce qui garantit un YAML valide.

### Makefile

Raccourcis pour les opérations courantes. Détecte automatiquement `docker compose` (plugin) ou `docker-compose` (binaire standalone).

### Templates nginx

| Template | Utilisé par | Description |
|----------|-------------|-------------|
| `matrix.conf.template` | Mode Autonome | HTTPS + redirection HTTP→HTTPS + fédération port 8448. TLSv1.2/1.3, HSTS, OCSP Stapling. |
| `matrix-init.conf.template` | Mode Autonome | HTTP temporaire pour le challenge ACME certbot. Remplacé par `matrix.conf.template` après obtention du certificat. |
| `matrix-local.conf.template` | Mode Local | HTTP simple sans SSL. Sert les `.well-known` et proxie vers Synapse. |

Tous les templates utilisent le placeholder `MATRIX_DOMAIN_PLACEHOLDER`, remplacé automatiquement par `setup.sh`.

---

## Réseau et ports

### Réseaux Docker

| Réseau | Type | Utilisé par | Description |
|--------|------|-------------|-------------|
| `matrix-net` | bridge (interne) | synapse, postgres, nginx | Communication inter-services |
| `proxy` | external | synapse, traefik | Réseau partagé avec Traefik (mode Traefik uniquement) |

### Ports exposés

| Mode | Port hôte | Service | Usage |
|------|-----------|---------|-------|
| **Traefik** | — | synapse (8008 interne) | Routé via Traefik sur le port 443 de l'hôte |
| **Autonome** | 80 | nginx | HTTP → redirection HTTPS + challenge ACME |
| **Autonome** | 443 | nginx | HTTPS → proxy vers Synapse |
| **Autonome** | 8448 | nginx | Fédération Matrix (TLS) |
| **Local** | 8090 (configurable) | nginx | HTTP → proxy vers Synapse |

> En mode Traefik, aucun port n'est publié directement par les conteneurs de ce projet. Traefik route les requêtes via le réseau Docker `proxy`.

---

## Configuration Synapse

Le fichier `data/synapse/homeserver.yaml` est généré automatiquement par `setup.sh`. Voici les principales options configurées :

### Options appliquées automatiquement

| Option | Valeur | Description |
|--------|--------|-------------|
| `server_name` | `$MATRIX_SERVER_NAME` | Nom du serveur (dans les IDs utilisateurs) |
| `public_baseurl` | `https://$MATRIX_DOMAIN/` | URL publique du serveur |
| `database` | PostgreSQL | Connexion via le service Docker `postgres` |
| `serve_server_wellknown` | `true` (prod/traefik) | Synapse sert les endpoints `.well-known` |
| `enable_registration` | `false` | Inscription publique désactivée par défaut |
| `allow_public_rooms_over_federation` | `false` | Annuaire des salons non exposé en fédération |
| `allow_public_rooms_without_auth` | `false` | Annuaire des salons requiert une authentification |
| `report_stats` | `false` | Pas de télémétrie envoyée à matrix.org |

### Options modifiables manuellement

Ajoutez ces options dans `data/synapse/homeserver.yaml` selon vos besoins, puis redémarrez avec `docker compose restart synapse` :

```yaml
# Taille max des uploads média (défaut : 50M)
max_upload_size: 100M

# Durée de rétention des médias distants dans le cache (défaut : 90d)
remote_media_lifetime: 30d

# Activer les aperçus d'URL dans les salons
url_preview_enabled: true
url_preview_ip_range_blacklist:
  - '127.0.0.0/8'
  - '10.0.0.0/8'
  - '172.16.0.0/12'
  - '192.168.0.0/16'
  - '100.64.0.0/10'
  - '192.0.0.0/24'
  - '169.254.0.0/16'
  - '198.18.0.0/15'
  - 'fe80::/10'
  - 'fc00::/7'
  - '::1/128'

# Rétention automatique des messages (purge des anciens événements)
retention:
  enabled: true
  default_policy:
    min_lifetime: 1d
    max_lifetime: 365d

# Limiter les requêtes (rate limiting)
rc_message:
  per_second: 0.5
  burst_count: 10

# Désactiver la présence (réduit la charge serveur)
presence:
  enabled: false
```

### Fichiers sensibles générés

| Fichier | Description | Régénérable |
|---------|-------------|:-----------:|
| `homeserver.yaml` | Configuration principale | ✔ (via `setup.sh`) |
| `*.signing.key` | Clé de signature du serveur | ✘ (unique, ne pas supprimer) |
| `*.log.config` | Configuration des logs Python | ✔ |
| `registration_shared_secret` (dans yaml) | Secret pour `register_new_matrix_user` | ✔ |
| `macaroon_secret_key` (dans yaml) | Secret pour les tokens de session | ✘ (invalide les sessions) |
| `form_secret` (dans yaml) | Secret pour les formulaires | ✔ |

> **⚠️ Ne supprimez jamais la `signing.key`** — elle identifie votre serveur auprès des autres serveurs fédérés. Sa perte rend la fédération irréparable.

---

## Mise à jour

### Mettre à jour Synapse

```bash
docker compose pull synapse
docker compose up -d synapse
```

Synapse applique les migrations de base de données automatiquement au démarrage.

### Mettre à jour tous les services

```bash
docker compose pull
docker compose up -d
```

### Vérifier la version actuelle

```bash
curl -s https://votre.domaine/_matrix/federation/v1/version
```

Ou en local :

```bash
docker compose exec synapse curl -s http://localhost:8008/_matrix/federation/v1/version
```

---

## Dépannage

### Synapse redémarre en boucle

```bash
docker logs matrix-synapse --tail=50
```

| Erreur | Cause | Solution |
|--------|-------|----------|
| `password authentication failed` | Mot de passe PostgreSQL changé après l'initialisation de la BDD | `docker compose down && sudo rm -rf data/postgres && docker compose up -d` |
| `enable_registration without verification` | `enable_registration: true` sans méthode de vérification | Mettre `enable_registration: false` ou activer captcha/token |
| `Fichier introuvable` (log.config, signing.key) | Fichiers de config manquants | Relancer `sudo bash setup.sh` |
| `eenable_registration` / erreur YAML | Faute de frappe dans `homeserver.yaml` | Vérifier la syntaxe YAML du fichier |

### 404 sur l'URL du serveur

- Synapse ne sert rien à la racine `/` — c'est normal
- Testez l'API : `curl https://votre.domaine/_matrix/client/versions`
- Vérifiez que `MATRIX_DOMAIN` correspond au domaine DNS
- En mode Traefik : vérifiez que le conteneur est sur le réseau `proxy` → `docker network inspect proxy`

### Erreur reCAPTCHA « Domaine non valide pour la clé de site »

Le reCAPTCHA est vérifié côté navigateur, donc le domaine validé est celui du **client web** (ex : `app.element.io`), pas celui de votre serveur Matrix.

Solutions :
1. Ajoutez les domaines des clients web dans la configuration reCAPTCHA (voir [Option 1 — Captcha](#option-1--inscription-avec-captcha-recommandé))
2. Décochez « Validation du domaine » dans les paramètres reCAPTCHA (moins sécurisé)

### PostgreSQL ne démarre pas

```bash
docker logs matrix-postgres --tail=30
```

- Vérifiez les permissions : `sudo chown -R 999:999 data/postgres/`
- Si la base est corrompue : `docker compose down && sudo rm -rf data/postgres && docker compose up -d` (⚠️ perte de données — restaurez depuis une sauvegarde)

### Vérifier que le serveur fonctionne

```bash
# API client
curl https://votre.domaine/_matrix/client/versions

# Fédération
curl https://votre.domaine/_matrix/federation/v1/version

# Healthcheck
docker compose exec synapse curl -s http://localhost:8008/health
```

Réponse attendue pour `/versions` : un JSON listant les versions de l'API supportées.

### Consulter les logs en temps réel

```bash
# Tous les services
make logs

# Un service spécifique
docker compose logs -f synapse
docker compose logs -f postgres
```

---

## Licence

Ce projet est distribué sous licence MIT.
