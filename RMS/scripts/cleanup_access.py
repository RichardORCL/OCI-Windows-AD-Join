"""Remove this instance's bootstrap tag and probe Vault revocation without output.
Exit codes: 0 success/denied, 10 Vault still readable, 1 cleanup/probe failure.
"""
import copy
import json
import logging
import os
import sys
import urllib.request


def metadata():
    request = urllib.request.Request(
        "http://169.254.169.254/opc/v2/instance/",
        headers={"Authorization": "Bearer Oracle"},
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=10) as response:
        return json.load(response)


def has_bootstrap_tag(tags, config):
    # A different value is still removed: the entire bootstrap key is temporary.
    return config["tag_key"] in (tags or {}).get(config["tag_namespace"], {})


def remove_tag(oci, config, signer):
    identity = metadata()
    instance_id = identity["id"]  # Never accept a target OCID from caller input.
    client = oci.core.ComputeClient(
        {"region": config["region"]}, signer=signer,
        timeout=(10, 60), retry_strategy=oci.retry.NoneRetryStrategy(),
    )
    for _ in range(3):
        try:
            current = client.get_instance(instance_id)
        except oci.exceptions.ServiceError as error:
            # A previous update may have succeeded even if its response was lost.
            # After revocation the instance can no longer GetInstance. IMDS v2
            # can confirm absence without requiring any cloud API permission.
            latest = metadata()
            if error.status in (403, 404) and "definedTags" in latest and not has_bootstrap_tag(latest["definedTags"], config):
                return
            raise
        tags = copy.deepcopy(current.data.defined_tags or {})
        if not has_bootstrap_tag(tags, config):
            return
        del tags[config["tag_namespace"]][config["tag_key"]]
        if not tags[config["tag_namespace"]]:
            del tags[config["tag_namespace"]]
        try:
            updated = client.update_instance(
                instance_id,
                oci.core.models.UpdateInstanceDetails(defined_tags=tags),
                if_match=current.headers["etag"],
            )
        except oci.exceptions.ServiceError as error:
            if error.status == 412:
                continue  # Preserve any concurrent tag changes; re-read the ETag.
            raise
        if has_bootstrap_tag(updated.data.defined_tags, config):
            raise RuntimeError("Bootstrap tag still present")
        return
    raise RuntimeError("Concurrent tag updates prevented cleanup")


def verify_revocation(oci, config, signer):
    client = oci.secrets.SecretsClient(
        {"region": config["region"]}, signer=signer,
        timeout=(10, 60), retry_strategy=oci.retry.NoneRetryStrategy(),
    )
    try:
        # Only a real API authorization check demonstrates that access is denied.
        # While propagation is pending, any returned bundle is discarded in memory.
        client.get_secret_bundle(config["secret_id"], stage="CURRENT")
    except oci.exceptions.ServiceError as error:
        if error.status in (403, 404):
            return 0
        raise  # DNS, authentication, throttling and server errors prove no revocation.
    return 10


def main():
    root = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, os.path.join(root, "sdk"))
    import oci

    logging.disable(logging.CRITICAL)
    with open(os.path.join(root, "config.json"), encoding="utf-8-sig") as stream:
        config = json.load(stream)
    signer = oci.auth.signers.InstancePrincipalsSecurityTokenSigner(log_requests=False)
    mode = sys.argv[1]
    if mode == "remove-tag":
        remove_tag(oci, config, signer)
        return 0
    if mode == "verify-revocation":
        return verify_revocation(oci, config, signer)
    raise ValueError("Unknown cleanup operation")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.stderr.write("Bootstrap access cleanup failed; check IAM, tag and API connectivity.\n")
        sys.exit(1)
