# CS 454/554 Project 1: Portable Containerized REST Service

A REST service that converts pounds to kilograms. It runs as two containers under
Compose: a Node.js/Express **app** and a **Redis** instance. Redis keeps a
persistent count of successful conversions in a named volume.

The API follows [`convert-api.openapi.yaml`](convert-api.openapi.yaml).

| Endpoint | Behavior |
| --- | --- |
| `GET /convert?lbs=<number>` | `200 {lbs, kg, formula}`, with `kg` rounded to 3 decimals, and increments the Redis key `conversions`. `400` if `lbs` is missing or not a number, `422` if it is negative or non-finite (e.g. `Infinity`). Invalid requests are never counted. |
| `GET /stats` | `200 {conversions}`, read from Redis. **Returns `503`** (optional in the spec, implemented here) if Redis cannot be read, instead of a misleading count. |
| `GET /health` | `200 {"status":"ok"}`. An application liveness check that does not depend on Redis (see [Design Decisions](#design-decisions)). |

## Layout

```text
.
Dockerfile                 # app image: node:22-alpine, npm ci, non-root user
.dockerignore              # keeps node_modules, .git, docs, tests out of the build context
compose.yaml               # app + redis, private network, named volume, health checks
convert-api.openapi.yaml   # authoritative API contract
package.json / package-lock.json
src/
   server.js              # Express app, Redis client, graceful shutdown
   healthcheck.js         # container health probe (GET /health via built-in fetch)
test/
   smoke.sh               # automated test of every required case
scripts/
   demo.sh                # runs the full operational demonstration
evidence/
    smoke-test.txt         # captured test output
    operational-demo.txt   # captured 10-step operational demonstration
    redis-outage.txt       # captured failure scenario (graduate extension)
```

## Prerequisites

- Docker Engine / Docker Desktop with Compose v2 (`docker compose version`), **or** Podman with `podman compose`
- `curl` and `bash` (for the tests)
- Host port `8080` free (or override it, see below)
- Optional: Node.js 20+ if you want to run the app outside a container

## Build and start

From a clean checkout, in this directory:

```bash
docker compose up -d --build --wait
```

That single command builds the app image, creates the `backend` network and
the `redis-data` volume, starts Redis, waits for Redis to be healthy, starts the
app, and returns once the app's own health check passes.

The API is then available at `http://localhost:8080`. To publish on a different
host port, without changing the image or the file:

```bash
APP_HOST_PORT=9090 docker compose up -d --build --wait
```

To build the image only: `docker compose build`.

## Test

Run the automated smoke test against the running stack:

```bash
./test/smoke.sh
# or: BASE_URL=http://localhost:9090 ./test/smoke.sh
```

It checks the status code **and** the exact JSON body for every required case.
It also reads `/stats` before and after, which proves that the three valid
conversions add exactly 3 and the invalid requests add 0. It exits non-zero on
any failure. Captured output: [`evidence/smoke-test.txt`](evidence/smoke-test.txt).

Or test each endpoint by hand:

```bash
curl -i http://localhost:8080/health                 # 200 {"status":"ok"}
curl -i "http://localhost:8080/convert?lbs=0"        # 200 {"lbs":0,"kg":0,...}
curl -i "http://localhost:8080/convert?lbs=150"      # 200 {"lbs":150,"kg":68.039,...}
curl -i "http://localhost:8080/convert?lbs=0.1"      # 200 {"lbs":0.1,"kg":0.045,...}
curl -i  http://localhost:8080/convert               # 400
curl -i "http://localhost:8080/convert?lbs=abc"      # 400
curl -i "http://localhost:8080/convert?lbs=-5"       # 422
curl -i  http://localhost:8080/stats                 # 200 {"conversions":3}
```

### Operational demonstration

[`scripts/demo.sh`](scripts/demo.sh) runs all ten required steps in order:
build, start, health, two conversions, stats, logs, `down` while keeping the
volume, recreate, stats still correct, and full cleanup. It prints each command
before its output.

```bash
./scripts/demo.sh 2>&1 | tee evidence/operational-demo.txt
```

> The script begins and ends with `docker compose down -v`, so it deletes any
> existing conversion count.

Captured run: [`evidence/operational-demo.txt`](evidence/operational-demo.txt).

## Logs and inspection

```bash
docker compose ps                    # state and health of each service, published ports
docker compose logs app              # app logs: one line per request, Redis connect/reconnect events
docker compose logs -f app           # follow live
docker compose logs redis
docker compose exec app id           # uid=1000(node): the app is not root
docker inspect --format '{{json .State.Health}}' cs454-project1-app-1   # health-check history
docker network inspect cs454-project1_backend                           # who is on the private network
docker volume inspect cs454-project1_redis-data                         # where the Redis data lives
docker compose exec redis redis-cli GET conversions                     # the raw counter, from inside the network
```

## Stop and clean up

| Command | Containers | Network | Volume (count) |
| --- | --- | --- | --- |
| `docker compose stop` | stopped, still exist (`docker compose start` resumes them) | kept | kept |
| `docker compose down` | removed | removed | **kept**, so the next `up` sees the same count |
| `docker compose down -v` | removed | removed | **deleted**, so the count is gone |

Full cleanup, including the built image:

```bash
docker compose down -v
docker image rm cs454-project1-app:1.0.0
```

Podman users can substitute `podman compose` for `docker compose` throughout.

## Running without containers (optional)

```bash
npm install
REDIS_HOST=localhost PORT=3000 npm start      # needs a Redis reachable at REDIS_HOST:REDIS_PORT
BASE_URL=http://localhost:3000 ./test/smoke.sh
```

## Configuration

Everything is set through environment variables in `compose.yaml`. Nothing is
baked into the image.

| Variable | Default in code | Set by Compose | Purpose |
| --- | --- | --- | --- |
| `PORT` | `3000` | `8080` | Port the app listens on inside the container |
| `REDIS_HOST` | `localhost` | `redis` | Redis hostname (the Compose service name) |
| `REDIS_PORT` | `6379` | `6379` | Redis port |
| `SERVICE_NAME` | `cs454-project1` | `cs454-project1` | Name reported by `GET /` and in logs |
| `APP_HOST_PORT` | n/a | `8080` | Host port that Compose publishes (Compose-level, not seen by the app) |

## Design Decisions

### How the application locates Redis

The app reads `REDIS_HOST` and `REDIS_PORT` from its environment, and
`compose.yaml` sets `REDIS_HOST=redis`. Both services join the user-defined
`backend` network. The runtime's embedded DNS server on that network maps each
service name to its container's current IP. The IP changes whenever the Redis
container is recreated, but the name does not, so nothing in the code or image
hard-codes an address. The same image works against any Redis by changing one
variable.

### Why Redis is not exposed to the host

Redis has no `ports:` entry, so port 6379 is reachable only from containers on
the `backend` network. The app is its only legitimate client. Redis runs
without authentication by default, and publishing it would let anything that
can reach the host read or overwrite the counter, or run commands like
`FLUSHALL` and `CONFIG`. Keeping it private also means the app's HTTP API is the
only interface, so all writes go through its validation. The app's own published
port is bound to `127.0.0.1`, so the only exposed port is not reachable from
other machines on the network either. The captured demo shows
`/cs454-project1-redis-1 ports={"6379/tcp":null}`.

### Why the Redis volume is separate from the Redis container

A container's writable layer lives only as long as the container does.
`docker compose down`, an image upgrade, or a crash-and-recreate would each wipe
it. The named volume `redis-data` is mounted at `/data`. It has its own
lifecycle and outlives any particular container, so the counter survives
container recreation, as step 9 of the demo shows. Redis also runs with
`--appendonly yes`, so each `INCR` is written to the append-only file in
`/data`, not only to periodic snapshots. Only an explicit `down -v` deletes the
volume. This keeps the rule that containers are disposable and state is not.

### `/health` is liveness, not readiness

`/health` returns `200` as long as the Node process can serve HTTP. It does not
check Redis. If it did, a brief Redis restart would mark the *app* container
unhealthy, even though restarting the app would fix nothing. A Redis outage
shows up where it matters: `/stats` and `/convert` return `503`. The health probe
([`src/healthcheck.js`](src/healthcheck.js)) uses Node's built-in `fetch`, so the
image does not need `curl` or `wget`.

### Image choices

- `node:22-alpine`: a pinned major version on a small base. `redis:7.4-alpine` is pinned the same way.
- The manifests are copied first and installed with `npm ci --omit=dev`, so the
  install layer stays cached until dependencies change. The versions come
  exactly from `package-lock.json`, and no dev dependencies are installed.
- Only `src/` is copied in. `.dockerignore` excludes `node_modules`, `.git`,
  `.env`, docs, tests and evidence. Host `node_modules` never enters the image.
- `USER node` (uid 1000) runs the app. The files it runs stay owned by root, so a
  compromised process cannot rewrite its own code.
- The exec-form `CMD` makes `node` PID 1, so it receives `SIGTERM` directly. The
  handler closes the HTTP server and the Redis connection, then exits 0 (see the
  step 7 logs in the demo).

### Containers vs. installing both services directly on a VM

**Benefit: reproducibility and portability.** The image carries the exact Node
runtime and the locked dependencies. One `docker compose up` gives the same
result on a laptop, a lab machine or a cloud VM. A VM install depends on the
distro's Node and Redis packages, on hand-written systemd units, and on steps
that tend to drift from machine to machine.

**Limitation: an extra layer to operate and debug.** You need a container
runtime, and state now lives in a runtime-managed volume, not in a plain path
like `/var/lib/redis`. Networking passes through NAT and published ports.
Problems like a port conflict, a stale volume, or DNS on the Compose network
require container-specific knowledge. On a VM, the same issues show up with
ordinary OS tools.

**More detailed tradeoffs (CS 554):**

| Concern | Compose (this project) | Both services on one VM |
| --- | --- | --- |
| Isolation and security | Redis is on a private bridge network with no host port. The app runs as uid 1000 in its own filesystem and process namespace. | Redis usually listens on `127.0.0.1`. Any process or user on the VM can reach it, and a compromised app shares the whole OS with Redis. |
| Dependencies and upgrades | Each service brings its own runtime. Upgrading Redis means changing one tag and recreating the container. Rolling back means going back to the old tag. | Node and Redis come from the OS package manager and share system libraries. Upgrades happen in place and are harder to roll back. |
| State and backup | State is in a named volume managed by the runtime. You back it up with `docker run --volumes-from` or a volume export. It is easy to delete by accident with `down -v`. | State is a normal directory, easy to find and back up with standard tools. There is no runtime command that can delete it by accident. |
| Performance and overhead | Small overhead from the container runtime, NAT on the published port, and (on macOS/Windows) the hidden Linux VM Docker Desktop runs. | Native processes and loopback networking, with no extra layer. |
| Process supervision | `restart: unless-stopped` and health checks are declared next to the service in `compose.yaml`. | You write and maintain separate systemd units, including `Restart=` and dependency ordering. |
| Scaling path | The same images move to Kubernetes or Swarm largely unchanged, and the app can be scaled horizontally because its state is external. | Scaling means provisioning and configuring more VMs by hand or with configuration management. |

### Restart policy (CS 554)

Both services use `restart: unless-stopped`. The runtime restarts a container
when its main process exits (a crash or an uncaught error) and when the Docker
daemon or host restarts. It does **not** restart a container you stopped on
purpose with `docker compose stop`, so manual maintenance is respected.
`depends_on: condition: service_healthy` controls startup order only. The first
time, the app waits for Redis to answer `PING`, but the policy does not restart
the app when Redis later fails. Also note that a failing health check alone
does not make plain Docker restart a container. It only marks it `unhealthy`.
An orchestrator such as Swarm or Kubernetes, or an external monitor, would act
on that status.

### Failure scenario: Redis goes down while the app is running (CS 554)

Captured in [`evidence/redis-outage.txt`](evidence/redis-outage.txt):

1. The Redis connection drops. The client logs the error and keeps
   reconnecting, backing off up to 3 s. The app process keeps running.
2. `/health` still returns `200` and the app container stays **healthy** with
   **0 restarts**. The app itself is fine, and restarting it would not bring
   Redis back.
3. `/stats` returns `503` instead of a stale or zero count. `/convert` also returns
   `503`, because a conversion only counts as successful once it has been recorded.
   Returning `200` without incrementing would make `/stats` undercount without
   anyone noticing. The client's offline queue is disabled, so these failures
   come back in about 1 ms instead of hanging.
4. When Redis returns (restarted by `restart: unless-stopped` after a crash, or
   by hand), the client reconnects automatically. Because the data is in the
   volume with AOF enabled, the count is exactly what it was before the outage.
   No app restart is needed.

The remaining gap: if Redis crashed after an `INCR` was applied but before
the reply reached the app, the client would get an error and return `503`, but
the count would already have gone up by one. A single-instance design cannot
avoid this without idempotency keys, and for a usage counter the tradeoff is
acceptable.
