import httpx

from config import OLLAMA_BASE


async def ollama_get(path: str, base_url: str = OLLAMA_BASE) -> dict:
    async with httpx.AsyncClient(timeout=5) as client:
        r = await client.get(f"{base_url}{path}")
        r.raise_for_status()
        return r.json()
