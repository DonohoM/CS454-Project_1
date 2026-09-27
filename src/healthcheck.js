// Container health probe: exits 0 if GET /health answers 200, 1 otherwise.
// Uses Node's built-in fetch so the image needs no curl or wget.
const port = Number(process.env.PORT || 3000);

fetch(`http://127.0.0.1:${port}/health`, { signal: AbortSignal.timeout(2000) })
  .then((res) => process.exit(res.ok ? 0 : 1))
  .catch(() => process.exit(1));
