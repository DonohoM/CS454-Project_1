const express = require('express');
const { createClient } = require('redis');

const app = express();

// Runtime configuration comes from the environment, never from hard-coded values.
// Keep it that way as you add Redis: the image you build must be usable without
// rebuilding it for a different host, port, or backing service.
const port = Number(process.env.PORT || 3000);
const serviceName = process.env.SERVICE_NAME || 'cs454-project1';

// Redis connection settings. Under Compose, REDIS_HOST is the Redis service name,
// which Compose's DNS resolves on the private network -- never a container IP.
const redisHost = process.env.REDIS_HOST || 'localhost';
const redisPort = Number(process.env.REDIS_PORT || 6379);

const COUNTER_KEY = 'conversions';
const LBS_TO_KG = 0.45359237;
const FORMULA = 'kg = lbs * 0.45359237';

// The client reconnects on its own if Redis goes away (backing off up to 3s).
// disableOfflineQueue makes commands fail immediately while disconnected instead
// of queueing, so a Redis outage becomes a fast 503 rather than a hung request.
const redis = createClient({
  socket: {
    host: redisHost,
    port: redisPort,
    connectTimeout: 2000,
    reconnectStrategy: (retries) => Math.min(retries * 200, 3000)
  },
  disableOfflineQueue: true
});

// Without an 'error' listener a lost connection would crash the process.
redis.on('error', (err) => console.error(`Redis error: ${err.message}`));
redis.on('ready', () => console.log(`Connected to Redis at ${redisHost}:${redisPort}`));
redis.on('reconnecting', () => console.log(`Reconnecting to Redis at ${redisHost}:${redisPort}...`));

// Basic request logging. Container logs are your primary debugging tool for this
// project, so keep writing to stdout/stderr rather than to a file inside the image.
app.use((req, res, next) => {
  const startedAt = process.hrtime.bigint();

  res.on('finish', () => {
    const elapsedMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
    console.log(
      `${new Date().toISOString()} ${req.method} ${req.originalUrl} ${res.statusCode} ${elapsedMs.toFixed(1)}ms`
    );
  });

  next();
});

app.get('/', (req, res) => {
  res.json({
    service: serviceName,
    message: 'CS 454/554 Project 1 starter is running.'
  });
});

// Decimal numbers only ("150", "0.1", ".5", "-5", "1e3"). Number() alone would
// also accept "", "0x10" and "  ", which are not what a caller means by lbs.
const DECIMAL_NUMBER = /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/;
const INFINITY = /^[+-]?Infinity$/;

// Returns { lbs } on success or { status, error } describing why the value is invalid.
function parseLbs(raw) {
  if (typeof raw !== 'string' || !(DECIMAL_NUMBER.test(raw) || INFINITY.test(raw))) {
    return { status: 400, error: 'Query parameter lbs is required and must be a number.' };
  }

  const lbs = Number(raw);
  if (!Number.isFinite(lbs) || lbs < 0) {
    return { status: 422, error: 'lbs must be a non-negative, finite number.' };
  }

  return { lbs };
}

function roundTo3(value) {
  const scaled = value * 1000;
  return Number.isFinite(scaled) ? Math.round(scaled) / 1000 : value;
}

app.get('/convert', async (req, res) => {
  const parsed = parseLbs(req.query.lbs);
  if (parsed.error) {
    return res.status(parsed.status).json({ error: parsed.error });
  }

  // Count first, respond second: a conversion is only reported as successful
  // once it has been recorded, so /stats never undercounts 200 responses.
  try {
    await redis.incr(COUNTER_KEY);
  } catch (err) {
    console.error(`Failed to record conversion: ${err.message}`);
    return res.status(503).json({ error: 'Conversion could not be recorded; state store unavailable.' });
  }

  const { lbs } = parsed;
  res.json({ lbs, kg: roundTo3(lbs * LBS_TO_KG), formula: FORMULA });
});

app.get('/stats', async (req, res) => {
  try {
    const value = await redis.get(COUNTER_KEY);
    res.json({ conversions: Number(value ?? 0) });
  } catch (err) {
    console.error(`Failed to read conversion count: ${err.message}`);
    res.status(503).json({ error: 'Conversion statistics are temporarily unavailable.' });
  }
});

// Liveness only: answers as long as this process can serve HTTP. It deliberately
// does not touch Redis, so a Redis restart shows up as 503s on /stats rather
// than as an "unhealthy" app container that the runtime might restart.
app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

// Error bodies match the ErrorResponse schema in convert-api.openapi.yaml:
// a single `error` string and nothing else. The requested path is already in
// the log line above, so it does not need to go in the response.
app.use((req, res) => {
  res.status(404).json({ error: 'Not Found' });
});

const server = app.listen(port, '0.0.0.0', () => {
  console.log(`${serviceName} listening on port ${port}`);
});

// Connect in the background: the HTTP server (and /health) comes up even if
// Redis is not reachable yet, and the client keeps retrying until it is.
redis.connect().catch((err) => console.error(`Redis connect failed: ${err.message}`));

// Containers are stopped by signal, not by Ctrl-C. Handling SIGTERM lets the
// runtime shut the process down cleanly instead of killing it after a timeout.
let shuttingDown = false;

const shutdown = (signal) => {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`Received ${signal}, shutting down...`);

  // Don't let a stuck connection hold the container past its stop timeout.
  setTimeout(() => {
    console.error('Shutdown timed out; forcing exit.');
    process.exit(1);
  }, 8000).unref();

  server.close(async () => {
    console.log('Server closed.');
    try {
      if (redis.isReady) {
        await redis.close();
      } else {
        redis.destroy();
      }
      console.log('Redis connection closed.');
    } catch (err) {
      console.error(`Error closing Redis connection: ${err.message}`);
    }
    process.exit(0);
  });
};

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
