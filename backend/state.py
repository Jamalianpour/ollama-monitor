from collections import deque

recent_requests: deque = deque(maxlen=500)
log_lines: deque = deque(maxlen=500)
_valid_tokens: set[str] = set()
running_models: list = []                    # first server (backward compat)
server_running_models: dict[str, list] = {} # server_id → running models
