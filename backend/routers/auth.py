import secrets

import bcrypt
from fastapi import APIRouter, Depends, HTTPException

import database as db
from auth import require_auth
from state import _valid_tokens

router = APIRouter(tags=["auth"])


@router.get("/api/auth/status")
async def auth_status():
    return {"password_set": db.get_setting("password_hash") is not None}


@router.post("/api/auth/setup")
async def auth_setup(body: dict):
    if db.get_setting("password_hash") is not None:
        raise HTTPException(status_code=409, detail="Password already configured")
    password = body.get("password", "")
    if len(password) < 8:
        raise HTTPException(status_code=422, detail="Password must be at least 8 characters")
    hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
    db.set_setting("password_hash", hashed)
    token = secrets.token_urlsafe(32)
    _valid_tokens.add(token)
    db.create_session(token)
    return {"token": token}


@router.post("/api/auth/login")
async def auth_login(body: dict):
    password = body.get("password", "")
    stored = db.get_setting("password_hash")
    if stored is None:
        raise HTTPException(status_code=403, detail="No password configured yet")
    if not bcrypt.checkpw(password.encode(), stored.encode()):
        raise HTTPException(status_code=401, detail="Incorrect password")
    token = secrets.token_urlsafe(32)
    _valid_tokens.add(token)
    db.create_session(token)
    return {"token": token}


@router.post("/api/auth/logout")
async def auth_logout(token: str = Depends(require_auth)):
    _valid_tokens.discard(token)
    db.delete_session(token)
    return {"ok": True}


@router.post("/api/auth/change-password")
async def auth_change_password(body: dict, token: str = Depends(require_auth)):
    current = body.get("current_password", "")
    new_pass = body.get("new_password", "")
    stored = db.get_setting("password_hash")
    if not stored or not bcrypt.checkpw(current.encode(), stored.encode()):
        raise HTTPException(status_code=401, detail="Current password is incorrect")
    if len(new_pass) < 8:
        raise HTTPException(status_code=422, detail="New password must be at least 8 characters")
    hashed = bcrypt.hashpw(new_pass.encode(), bcrypt.gensalt()).decode()
    db.set_setting("password_hash", hashed)
    _valid_tokens.clear()
    db.delete_all_sessions()
    new_token = secrets.token_urlsafe(32)
    _valid_tokens.add(new_token)
    db.create_session(new_token)
    return {"token": new_token}
