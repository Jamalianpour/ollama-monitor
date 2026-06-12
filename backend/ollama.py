import httpx

from config import OLLAMA_BASE


async def ollama_get(path: str) -> dict:
    async with httpx.AsyncClient(timeout=5) as client:
        r = await client.get(f"{OLLAMA_BASE}{path}")
        r.raise_for_status()
        return r.json()
