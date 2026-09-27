#!/usr/bin/env bash
#
# Runs the Project 1 operational demonstration end to end and prints every
# command before its output, so the transcript can be captured as evidence:
#
#   ./scripts/demo.sh 2>&1 | tee evidence/operational-demo.txt
#
# WARNING: this starts and finishes with `docker compose down -v`, which deletes
# the project's Redis volume (and therefore the conversion count).

set -euo pipefail
cd "$(dirname "$0")/.."

BASE_URL="${BASE_URL:-http://localhost:8080}"

run() {
  printf '\n$ %s\n' "$*"
  "$@"
}

step() {
  printf '\n==== %s ====\n' "$*"
}

step "0. Start from a clean slate (no containers, network, or volume)"
run docker compose down -v --remove-orphans

step "1. Build the application image"
run docker compose build --no-cache app
run docker image ls cs454-project1-app

step "2. Start the complete system with one Compose command"
run docker compose up -d --wait
run docker compose ps

step "   Inspect: app runs as non-root; only the app publishes a port"
run docker compose exec app id
run docker inspect --format '{{.Name}} ports={{json .NetworkSettings.Ports}}' \
  cs454-project1-app-1 cs454-project1-redis-1
run docker network inspect --format '{{.Name}}: {{range .Containers}}{{.Name}} {{end}}' \
  cs454-project1_backend

step "3. Verify the application health endpoint"
run curl -sS -w '\nHTTP %{http_code}\n' "${BASE_URL}/health"
run docker inspect --format '{{.Name}} health={{.State.Health.Status}}' cs454-project1-app-1

step "4. Perform two successful conversions"
run curl -sS -w '\nHTTP %{http_code}\n' "${BASE_URL}/convert?lbs=150"
run curl -sS -w '\nHTTP %{http_code}\n' "${BASE_URL}/convert?lbs=0.1"

step "   (an invalid request, which must not be counted)"
run curl -sS -w '\nHTTP %{http_code}\n' "${BASE_URL}/convert?lbs=-5"

step "5. Verify /stats reports the expected count (2)"
run curl -sS -w '\nHTTP %{http_code}\n' "${BASE_URL}/stats"

step "6. Inspect application logs"
run docker compose logs app

step "7. Stop and remove the containers, keeping the named volume"
# `stop` only halts the containers (they still exist, as "Exited"); the app's
# SIGTERM handler logs a clean shutdown. `down` then removes containers and
# network but leaves the named volume alone.
run docker compose stop
run docker compose ps -a
run docker compose logs app --tail 4
run docker compose down
run docker compose ps -a
run docker volume ls --filter name=cs454-project1

step "8. Recreate the system"
run docker compose up -d --wait
run docker compose ps

step "9. Verify /stats still reports the previous count (2)"
run curl -sS -w '\nHTTP %{http_code}\n' "${BASE_URL}/stats"

step "10. Remove all project resources, including the named volume"
run docker compose down -v
run docker image rm cs454-project1-app:1.0.0
run docker volume ls --filter name=cs454-project1
run docker network ls --filter name=cs454-project1

printf '\nDemo complete.\n'
