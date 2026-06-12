import json

from fastapi import WebSocket

connected_clients: list[WebSocket] = []


async def broadcast(msg: dict):
    dead = []
    text = json.dumps(msg)
    for ws in connected_clients:
        try:
            await ws.send_text(text)
        except Exception:
            dead.append(ws)
    for ws in dead:
        connected_clients.remove(ws)
