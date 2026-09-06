// Minimal disposable HTTP stub upstream for the vps-gateway integration harness.
// No dependencies, no database, no filesystem writes — every request just echoes
// which lane answered it plus the request path, so the test driver can assert
// routing without needing the real Tapiz/Aura applications.
import http from "node:http";

const PORT = Number(process.env.STUB_PORT ?? 8080);
const LANE_NAME = process.env.STUB_LANE_NAME ?? "unknown-lane";
const HEALTH_PATH = process.env.STUB_HEALTH_PATH ?? "/health";

const server = http.createServer((req, res) => {
  const body = JSON.stringify({ lane: LANE_NAME, path: req.url, method: req.method });
  if (req.url === HEALTH_PATH) {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(body);
    return;
  }
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(body);
});

server.listen(PORT, () => {
  console.log(`[${LANE_NAME}] stub listening on :${PORT}, health at ${HEALTH_PATH}`);
});

for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
