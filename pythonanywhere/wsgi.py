"""
PythonAnywhere WSGI configuration for RaaS Framework.
Place this file content into your PythonAnywhere WSGI config file.
Path on PythonAnywhere: /var/www/yourusername_pythonanywhere_com_wsgi.py
"""

import sys
import os

# ── Point to your uploaded agent folder ──────────────────────────────────────
# On PythonAnywhere your files will be at /home/yourusername/raas/
# Change 'yourusername' to your actual PythonAnywhere username

PROJECT_DIR = '/home/yourusername/raas'

if PROJECT_DIR not in sys.path:
    sys.path.insert(0, PROJECT_DIR)

os.chdir(PROJECT_DIR)

# ── Load the FastAPI app via ASGI → WSGI adapter ─────────────────────────────
from raas_agent import app as fastapi_app
from asgiref.wsgi import WsgiToAsgi  # not needed — use asgi directly

# PythonAnywhere supports ASGI on paid plans only.
# On the FREE plan we wrap with a simple WSGI shim using 'a2wsgi'.

try:
    from a2wsgi import ASGIMiddleware
    application = ASGIMiddleware(fastapi_app)
except ImportError:
    # Fallback: run as plain WSGI with limited async support
    from asgiref.sync import async_to_sync
    application = fastapi_app
