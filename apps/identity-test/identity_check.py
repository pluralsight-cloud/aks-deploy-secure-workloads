"""Workload identity test harness.

Runs one check, prints a single redacted RESULT line, then keeps the pod
running so you can `kubectl exec` into it. The secret value is never printed.

RESULT lines:
  SUCCESS               token exchange and Key Vault read both worked
  TOKEN_EXCHANGE_FAILED Microsoft Entra ID refused to issue a token (trust)
  KEY_VAULT_DENIED      the token worked, Key Vault refused the request (permission)
"""
import os
import time

from azure.core.exceptions import ClientAuthenticationError, HttpResponseError
from azure.identity import WorkloadIdentityCredential
from azure.keyvault.secrets import SecretClient

VAULT_NAME = os.environ.get("KEY_VAULT_NAME", "kv-globomantics-orders")
SECRET_NAME = os.environ.get("SECRET_NAME", "orders-db-connection-string")
VAULT_URL = f"https://{VAULT_NAME}.vault.azure.net"


def short(text, limit=700):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[:limit] + " ..."


def main():
    credential = WorkloadIdentityCredential()

    # Step 1: trust. Can the pod's ServiceAccount token be exchanged for an Azure token?
    try:
        credential.get_token("https://vault.azure.net/.default")
    except ClientAuthenticationError as err:
        print("RESULT: TOKEN_EXCHANGE_FAILED", flush=True)
        print(f"detail: {short(err.message or err)}", flush=True)
        return

    # Step 2: permission. Is that identity allowed to read the secret?
    try:
        SecretClient(vault_url=VAULT_URL, credential=credential).get_secret(SECRET_NAME)
    except HttpResponseError as err:
        print("RESULT: KEY_VAULT_DENIED", flush=True)
        print(f"detail: HTTP {err.status_code} {short(err.message or err)}", flush=True)
        return

    print(f"RESULT: SUCCESS read secret '{SECRET_NAME}' from {VAULT_NAME} (value redacted)", flush=True)


if __name__ == "__main__":
    main()
    while True:
        time.sleep(3600)
