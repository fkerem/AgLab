.PHONY: config up down logs health provision reset

config:
	docker compose config

up:
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f --tail=100

health:
	scripts/healthcheck.sh

provision:
	scripts/provision_students.sh

reset:
	scripts/reset_environment.sh --yes
