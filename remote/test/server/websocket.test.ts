import test from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { WebSocket } from "ws";

import { createRelayWebSocketServer } from "../../src/server/websocket.js";

test("relay websocket server keeps text connections open for invalid UTF-8 frames", async () => {
  const server = createServer();
  const wss = createRelayWebSocketServer();
  let received = false;

  server.on("upgrade", (req, socket, head) => {
    wss.handleUpgrade(req, socket, head, (ws) => {
      ws.on("message", () => {
        received = true;
        ws.close(1000, "ok");
      });
      ws.on("error", (err) => {
        throw err;
      });
    });
  });

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;

  try {
    const client = new WebSocket(`ws://127.0.0.1:${port}`);
    await new Promise<void>((resolve, reject) => {
      client.once("open", resolve);
      client.once("error", reject);
    });

    client.send(Buffer.from([0xff, 0xfe, 0xfd]), { binary: false });

    await new Promise<void>((resolve, reject) => {
      client.once("close", () => resolve());
      client.once("error", reject);
    });
  } finally {
    wss.close();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  assert.equal(received, true);
});
