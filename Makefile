.PHONY: setup up down restart logs status admin backup renew-certs \
        shell-synapse shell-postgres

COMPOSE ?= $(shell if docker compose version >/dev/null 2>&1; then echo "docker compose"; elif command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"; else echo "docker compose"; fi)

# Lance l'installation complète (à exécuter en premier)
setup:
	@bash setup.sh

# Démarre tous les conteneurs
up:
	$(COMPOSE) up -d

# Arrête tous les conteneurs
down:
	$(COMPOSE) down

# Redémarre tous les conteneurs
restart:
	$(COMPOSE) restart

# Affiche les logs en temps réel (Ctrl+C pour quitter)
logs:
	$(COMPOSE) logs -f --tail=100

# État des conteneurs
status:
	$(COMPOSE) ps

# Crée un compte administrateur Matrix
admin:
	@read -r -p "Nom d'utilisateur admin : " user; \
	$(COMPOSE) exec synapse \
		register_new_matrix_user \
		-c /data/homeserver.yaml \
		-a -u "$$user" http://localhost:8008

# Sauvegarde la base de données et les données Synapse
backup:
	@mkdir -p backups
	@echo "Sauvegarde de la base de données PostgreSQL..."
	@$(COMPOSE) exec -T postgres \
		pg_dump -U "$${POSTGRES_USER:-synapse}" "$${POSTGRES_DB:-synapse}" \
		| gzip > "backups/db-$$(date +%Y%m%d-%H%M%S).sql.gz"
	@echo "Sauvegarde des données Synapse (hors médias)..."
	@tar -czf "backups/synapse-$$(date +%Y%m%d-%H%M%S).tar.gz" \
		--exclude='data/synapse/media_store' \
		data/synapse/
	@echo "Sauvegardes disponibles dans ./backups/"

# Renouvelle le certificat SSL Let's Encrypt et recharge nginx
renew-certs:
	@echo "Renouvellement des certificats SSL..."
	@$(COMPOSE) run --rm certbot renew --quiet
	@$(COMPOSE) exec nginx nginx -s reload
	@echo "Certificats renouvelés."

# Ouvre un shell dans le conteneur Synapse
shell-synapse:
	$(COMPOSE) exec synapse bash

# Ouvre un shell psql dans PostgreSQL
shell-postgres:
	$(COMPOSE) exec postgres psql -U $${POSTGRES_USER:-synapse}
