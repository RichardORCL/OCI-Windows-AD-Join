"""The sole stdout consumer is the parent PowerShell process, via an anonymous pipe.
No credential files, command-line credentials, SDK request logging or tracebacks.
"""
import base64
import json
import logging
import os
import sys


def main():
    root = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, os.path.join(root, "sdk"))
    import oci

    logging.disable(logging.CRITICAL)
    with open(os.path.join(root, "config.json"), encoding="utf-8-sig") as stream:
        config = json.load(stream)
    signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner(log_requests=False)
    client = oci.secrets.SecretsClient(
        {"region": config["region"]}, signer=signer,
        timeout=(10, 60), retry_strategy=oci.retry.DEFAULT_RETRY_STRATEGY,
    )
    bundle = client.get_secret_bundle(config["secret_id"], stage="CURRENT").data
    content = bundle.secret_bundle_content
    if content.content_type != "BASE64":
        raise ValueError("Unexpected secret content type")
    credentials = json.loads(base64.b64decode(content.content, validate=True).decode("utf-8-sig"))
    for key in ("username", "password"):
        if not isinstance(credentials.get(key), str) or not credentials[key]:
            raise ValueError("Invalid credential structure")
    # ASCII JSON avoids Windows code-page corruption of non-ASCII passwords.
    result = {k: credentials[k] for k in ("username", "password")}
    if config.get("config_from_vault"):
        if not isinstance(credentials.get("ad_join"), dict):
            raise ValueError("An ad_join configuration object is required")
        result["ad_join"] = credentials["ad_join"]
    sys.stdout.write(json.dumps(result, ensure_ascii=True))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Do not print SDK exceptions: they may contain response bodies.
        sys.stderr.write("Vault retrieval failed; check IAM, connectivity and secret format.\n")
        sys.exit(1)
