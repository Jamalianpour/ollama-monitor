from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from state import _valid_tokens

_bearer = HTTPBearer(auto_error=False)


def _is_valid_token(token: str) -> bool:
    return bool(token) and token in _valid_tokens


def require_auth(credentials: HTTPAuthorizationCredentials = Depends(_bearer)):
    if credentials is None or not _is_valid_token(credentials.credentials):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or missing token")
    return credentials.credentials
