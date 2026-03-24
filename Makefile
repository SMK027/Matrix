.PHONY: setup up down restart logs status admin backup renew-certs \
        shell-synapse shell-postgres

# Lance l'installation complète (à exécuter en premier)
setup:
	@bash setup.sh

# Démarre tous les conteneurs
up:
	docker compose up -d

# Arrête tous les conteneurs
down:
	docker compose down

# Redémarre tous les conteneurs
restart:
	docker compose restart

# Affiche les logs en temps réel (Ctrl+C pour quitter)
logs:
	docker compose logs -f --tail=100

# État des conteneurs
status:
	docker compose ps

# Crée un compte administrateur Matrix
admin:
	@read -r -p "Nom d'utilisateur admin : " user; \
	docker compose exec synapse \
		register_new_matrix_user \
		-c /data/homeserver.yaml \
		-a -u "$$user" http://localhost:8008

# Sauvegarde la base de données et les données Synapse
backup:
	@mkdir -p backups
	@echo "Sauvegarde de la base de données PostgreSQL..."
	@docker compose exec -T postgres \
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
	@docker compose run --rm certbot renew --quiet
	@docker compose exec nginx nginx -s reload
	@echo "Certificats renouvelés."

# Ouvre un shell dans le conteneur Synapse
shell-synapse:
	docker compose exec synapse bash

# Ouvre un shell psql dans PostgreSQL
shell-postgres:
	docker compose exec postgres psql -U $${POSTGRES_USER:-synapse}
