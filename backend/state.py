from collections import deque

recent_requests: deque = deque(maxlen=200)
log_lines: deque = deque(maxlen=500)
_valid_tokens: set[str] = set()
running_models: list = []
