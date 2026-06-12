import json

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from auth import _is_valid_token
from config import LOG_PATHS, OLLAMA_BASE
from state import log_lines, recent_requests
from websocket import broadcast, connected_clients

router = APIRouter()


@router.websocket("/ws")
async def websocket_endpoint(ws: WebSocket, token: str = ""):
    if not _is_valid_token(token):
        await ws.close(code=4001, reason="Unauthorized")
        return
    await ws.accept()
    connected_clients.append(ws)
    await ws.send_text(json.dumps({
        "type": "init",
        "data": {
            "logs": list(log_lines)[-100:],
            "requests": list(recent_requests)[-50:],
            "log_files": [{"path": str(p), "label": lbl} for p, lbl in LOG_PATHS],
            "ollama_host": OLLAMA_BASE,
        },
    }))
    try:
        while True:
            await ws.receive_text()
    except WebSocketDisconnect:
        if ws in connected_clients:
            connected_clients.remove(ws)
