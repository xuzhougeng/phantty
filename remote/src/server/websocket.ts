import { WebSocketServer } from "ws";

export function createRelayWebSocketServer(): WebSocketServer {
  return new WebSocketServer({
    noServer: true,
    skipUTF8Validation: true,
  });
}
