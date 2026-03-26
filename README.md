# Serveur Matrix Synapse

Déploiement clé en main d'un serveur [Matrix](https://matrix.org/) auto-hébergé basé sur **Synapse**, avec **PostgreSQL** comme base de données.

Deux modes de déploiement sont supportés :

| Mode | Reverse proxy | SSL | Cas d'usage |
|------|---------------|-----|-------------|
| **Traefik** | Traefik (externe) | Automatique via Traefik | VPS avec Traefik existant |
| **Autonome** | Nginx (inclus) | Let's Encrypt / Certbot | Serveur dédié |
| **Local** | Nginx (inclus) | Aucun | Développement / tests |

---

## Prérequis

- **Linux** (Debian, Ubuntu, CentOS, Fedora)
- **Docker** et **Docker Compose** (installés automatiquement par `setup.sh` si absents)
- Un **nom de domaine** pointant vers le serveur (ex: `matrix.mondomaine.fr`)
- **Port 443** accessible depuis Internet (géré par Traefik ou Nginx selon le mode)

### Mode Traefik uniquement

- Traefik déjà en place avec un réseau Docker `proxy`
- Un `certresolver` nommé `le` configuré dans Traefik

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

Variables à renseigner :

| Variable | Description | Exemple |
|----------|-------------|---------|
| `MATRIX_DOMAIN` | Domaine complet du serveur | `matrix.mondomaine.fr` |
| `MATRIX_SERVER_NAME` | Nom du serveur (pour les IDs utilisateurs) | `matrix.mondomaine.fr` |
| `POSTGRES_PASSWORD` | Mot de passe PostgreSQL (alphanumérique recommandé) | `Un_Mot_De_Passe_Fort` |
| `LETSENCRYPT_EMAIL` | Email pour Let's Encrypt (optionnel avec Traefik) | `admin@mondomaine.fr` |
| `REVERSE_PROXY` | Mettre `traefik` si Traefik gère le SSL | `traefik` |
| `SYNAPSE_ALLOW_REGISTRATION` | Inscription publique (`true` / `false`) | `false` |

> **⚠️ Mot de passe PostgreSQL** : utilisez uniquement des caractères alphanumériques pour éviter les problèmes d'échappement YAML. Évitez `$`, `#`, `!`, `'`, `"`.

### 3. Lancer l'installation

```bash
sudo bash setup.sh
```

Le script effectue automatiquement :

1. Installation de Docker et Docker Compose (si absents)
2. Validation du fichier `.env`
3. Création des répertoires de données
4. Génération de la configuration Synapse (avec PostgreSQL, URL publique, sécurité)
5. Obtention du certificat SSL (sauf en mode Traefik)
6. Démarrage de tous les services
7. Création optionnelle d'un compte administrateur

---

## Modes de déploiement

### Mode Traefik (VPS avec reverse proxy existant)

Ajoutez dans votre `.env` :

```dotenv
MATRIX_DOMAIN=matrix.mondomaine.fr
MATRIX_SERVER_NAME=matrix.mondomaine.fr
REVERSE_PROXY=traefik
```

Synapse est automatiquement exposé à Traefik via les labels Docker. Le certificat SSL est géré par Traefik. Nginx et Certbot ne sont pas démarrés.

### Mode autonome (serveur dédié)

N'ajoutez pas `REVERSE_PROXY`. Le script configure :
- **Nginx** comme reverse proxy (ports 80, 443, 8448)
- **Certbot** pour l'obtention automatique du certificat Let's Encrypt

```dotenv
MATRIX_DOMAIN=matrix.mondomaine.fr
MATRIX_SERVER_NAME=matrix.mondomaine.fr
LETSENCRYPT_EMAIL=admin@mondomaine.fr
```

### Mode local (développement)

Utilisez `docker-compose.dev.yml` et un domaine localhost :

```dotenv
MATRIX_DOMAIN=localhost
MATRIX_SERVER_NAME=localhost
HTTP_PORT=8090
```

```bash
docker compose -f docker-compose.dev.yml up -d
```

---

## Commandes utiles

Toutes les opérations courantes sont accessibles via le `Makefile` :

| Commande | Description |
|----------|-------------|
| `make setup` | Lancer l'installation complète |
| `make up` | Démarrer tous les conteneurs |
| `make down` | Arrêter tous les conteneurs |
| `make restart` | Redémarrer les conteneurs |
| `make logs` | Suivre les logs en temps réel |
| `make status` | État des conteneurs |
| `make admin` | Créer un compte administrateur |
| `make backup` | Sauvegarder la BDD et la config Synapse |
| `make renew-certs` | Renouveler le certificat SSL (mode autonome) |
| `make shell-synapse` | Ouvrir un shell dans le conteneur Synapse |
| `make shell-postgres` | Ouvrir un shell psql dans PostgreSQL |

---

## Gestion des utilisateurs

### Créer un administrateur

```bash
make admin
```

Ou manuellement :

```bash
docker compose exec synapse register_new_matrix_user \
  -c /data/homeserver.yaml \
  -a -u mon_admin \
  http://localhost:8008
```

### Créer un utilisateur standard

```bash
docker compose exec synapse register_new_matrix_user \
  -c /data/homeserver.yaml \
  -u mon_utilisateur \
  http://localhost:8008
```

Le script demande interactivement un mot de passe.

### Activer l'inscription publique

Par défaut, seul un administrateur peut créer des comptes (via `make admin`).
Pour permettre aux utilisateurs de s'inscrire eux-mêmes, trois options sont disponibles.

#### Option 1 — Inscription avec captcha (recommandé)

Protège contre le spam en exigeant un reCAPTCHA Google lors de l'inscription.

1. Créez des clés reCAPTCHA sur [Google reCAPTCHA Admin](https://www.google.com/recaptcha/admin) (type reCAPTCHA v2 « I'm not a robot »).

2. Ajoutez dans `data/synapse/homeserver.yaml` :

   ```yaml
   enable_registration: true
   enable_registration_captcha: true
   recaptcha_public_key: "VOTRE_CLE_PUBLIQUE"
   recaptcha_private_key: "VOTRE_CLE_PRIVEE"
   ```

3. Redémarrez Synapse :

   ```bash
   docker compose restart synapse
   ```

#### Option 2 — Inscription par token

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

#### Option 3 — Inscription libre sans vérification (déconseillé)

> **⚠️ Déconseillé en production** — expose le serveur au spam et à l'abus.

```yaml
enable_registration: true
enable_registration_without_verification: true
```

### Compatibilité des clients

| Client | Inscription classique | Nécessite MAS |
|--------|----------------------|---------------|
| [Element Web](https://app.element.io) | Oui | Non |
| [Element Desktop](https://element.io/download) (classique) | Oui | Non |
| [FluffyChat](https://fluffychat.im) | Oui | Non |
| [SchildiChat](https://schildi.chat) | Oui | Non |
| [Cinny](https://cinny.in) | Oui | Non |
| **Element X** (mobile) | **Non** | **Oui** |

> **Note sur Element X** : ce client exige Matrix Authentication Service (MAS),
> un service d'authentification externe non inclus dans cette installation.
> Utilisez Element classique ou un autre client compatible pour l'inscription et la connexion.

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

> **⚠️ Important** : le `server_name` ne peut plus être changé après la création du premier compte.

---

## Architecture

```
Matrix/
├── docker-compose.yml          # Production (Traefik ou autonome)
├── docker-compose.dev.yml      # Développement local
├── setup.sh                    # Script d'installation automatisé
├── Makefile                    # Commandes courantes
├── .env.example                # Modèle de configuration
├── nginx/
│   ├── matrix.conf.template        # Config HTTPS production
│   ├── matrix-init.conf.template   # Config HTTP temporaire (certbot)
│   ├── matrix-local.conf.template  # Config HTTP développement
│   └── conf.d/
│       └── matrix.conf             # Config active (générée)
└── data/
    ├── synapse/
    │   ├── homeserver.yaml         # Config Synapse (générée)
    │   ├── *.signing.key           # Clé de signature
    │   ├── *.log.config            # Config des logs
    │   └── media_store/            # Fichiers média
    ├── postgres/                   # Données PostgreSQL
    └── certbot/                    # Certificats SSL (mode autonome)
```

---

## Dépannage

### Synapse redémarre en boucle

```bash
docker logs matrix-synapse --tail=30
```

Causes fréquentes :
- **`password authentication failed`** : le mot de passe PostgreSQL dans `homeserver.yaml` ne correspond pas à celui utilisé lors de l'initialisation de PostgreSQL. Réinitialiser : `docker compose down && sudo rm -rf data/postgres && docker compose up -d`
- **`enable_registration without verification`** : mettre `enable_registration: false` dans `homeserver.yaml`
- **Fichier introuvable** (`log.config`, `signing.key`) : relancer `setup.sh` pour régénérer

### 404 sur l'URL du serveur

- Vérifiez que `MATRIX_DOMAIN` dans le `.env` du serveur correspond au domaine
- Testez `https://votre.domaine/_matrix/client/versions` — Synapse ne sert rien à `/`
- Vérifiez que le conteneur est sur le réseau Traefik : `docker network inspect proxy`

### Vérifier que le serveur fonctionne

```bash
curl https://votre.domaine/_matrix/client/versions
```

Réponse attendue : un JSON listant les versions supportées.

---

## Licence

Ce projet est distribué sous licence MIT.
