# Run `make help` for targets.
# Server-side targets run on the Ubuntu host; client-side targets on your Mac.

COMPOSE := docker compose --env-file .env -f web/compose.yaml

.PHONY: help policy-check policy keys host up down logs status validate validate-quick clean demo-break

help:
	@echo "Client side (Mac):"
	@echo "  make policy-check  render + validate policy (incl. tests) without applying"
	@echo "  make policy        validate, back up current policy, apply"
	@echo "  make keys          mint single-use tagged auth keys and print .env lines"
	@echo "  make validate      end-to-end checks -> evidence/validation-*.md"
	@echo "  make validate-quick  same, without the interactive SSH login"
	@echo "  make demo-break    DEMO: show the policy tests rejecting a forbidden grant (never applies)"
	@echo "Server side (Ubuntu host):"
	@echo "  make host          install Tailscale, join as tag:server with Tailscale SSH"
	@echo "  make up            start the cafe site behind the Tailscale sidecar"
	@echo "  make status        container + tailscale status"
	@echo "  make logs          follow cafe, helper + sidecar logs"
	@echo "  make down          stop the service (node state is kept)"
	@echo "  make clean         stop and delete node state (node must be re-keyed)"

# ---- client side -----------------------------------------------------------
policy-check:
	bash ./scripts/apply-policy.sh --dry-run

policy:
	bash ./scripts/apply-policy.sh

keys:
	@echo "TS_AUTHKEY_HOST=$$(bash ./scripts/mint-authkey.sh tag:server)"
	@echo "TS_AUTHKEY_WEB=$$(bash ./scripts/mint-authkey.sh tag:web)"

validate:
	bash ./scripts/validate.sh

validate-quick:
	SKIP_SSH=1 bash ./scripts/validate.sh

# ---- server side -----------------------------------------------------------
host:
	sudo bash ./scripts/bootstrap-host.sh

up:
	$(COMPOSE) up -d --build
	@sleep 5
	$(COMPOSE) ps
	@echo "Published host ports (should be none):"
	@docker ps --filter "name=ts-web" --filter "name=cafe-web" --filter "name=web-identity" --format '{{.Names}}: [{{.Ports}}]'

status:
	$(COMPOSE) ps
	docker exec ts-web tailscale status
	docker exec ts-web tailscale serve status

logs:
	$(COMPOSE) logs -f --tail=50

down:
	$(COMPOSE) down

clean:
	$(COMPOSE) down -v

demo-break:
	bash ./scripts/demo-break-policy.sh
