"""Orders API sample service.

Reads one secret from Azure Key Vault with a workload identity (no stored
credential) and reports whether that read worked. The secret value is never
returned or logged.
"""
import json
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from azure.core.exceptions import ClientAuthenticationError, HttpResponseError
from azure.identity import WorkloadIdentityCredential
from azure.keyvault.secrets import SecretClient

VERSION = "1.0.0"
PORT = int(os.environ.get("PORT", "8080"))
VAULT_NAME = os.environ.get("KEY_VAULT_NAME", "kv-globomantics-orders")
SECRET_NAME = os.environ.get("SECRET_NAME", "orders-db-connection-string")
CACHE_SECONDS = 30

# WorkloadIdentityCredential reads AZURE_CLIENT_ID, AZURE_TENANT_ID and
# AZURE_FEDERATED_TOKEN_FILE, which the AKS workload identity webhook injects.
_client = SecretClient(
    vault_url=f"https://{VAULT_NAME}.vault.azure.net",
    credential=WorkloadIdentityCredential(),
)
_last = {"at": 0.0, "ok": False, "reason": "not checked yet"}


def check_key_vault():
    """Return (ok, reason). Only the success/failure is kept, never the value."""
    now = time.time()
    if now - _last["at"] < CACHE_SECONDS:
        return _last["ok"], _last["reason"]
    try:
        _client.get_secret(SECRET_NAME)
        ok, reason = True, "secret read succeeded"
    except ClientAuthenticationError:
        ok, reason = False, "token exchange failed"
    except HttpResponseError as err:
        ok, reason = False, f"key vault returned HTTP {err.status_code}"
    except Exception as err:  # noqa: BLE001 - report the class, not details
        ok, reason = False, f"unexpected error: {type(err).__name__}"
    _last.update(at=now, ok=ok, reason=reason)
    return ok, reason


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - http.server naming
        ok, reason = check_key_vault()
        body = {
            "service": "orders-api",
            "version": VERSION,
            "keyVaultConfig": "loaded" if ok else "unavailable",
            "secretName": SECRET_NAME,
            "secretValue": "redacted",
            "detail": reason,
        }
        payload = json.dumps(body).encode()
        self.send_response(200 if ok else 503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)


if __name__ == "__main__":
    print(f"orders-api {VERSION} listening on :{PORT}", flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
