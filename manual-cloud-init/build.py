"""Build the self-contained manual-launch script from the shared runtime sources."""
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent / "RMS"


MANUAL_DEFAULTS = {
    "manual_metadata": True,
    "secret_id": "",
    "domain": "",
    "computer_name": "",
    "override_dns": False,
    "dns_servers": [],
    "ou_path": "",
    "config_from_vault": False,
    "tag_namespace": "ADJoinBootstrap",
    "tag_key": "State",
    "tag_value": "pending",
}


def package_manual(destination=None):
    """Generate one self-contained Cloudbase-Init file from the stack's sources."""
    import base64
    import gzip
    import json

    destination = destination or HERE / "oci-windows-ad-cloud-init.ps1"
    template = (ROOT / "scripts/bootstrap.ps1.tftpl").read_text()
    names = {
        "worker_base64": "join-domain.ps1",
        "helper_base64": "read_secret.py",
        "cleanup_base64": "cleanup_access.py",
        "logging_base64": "stage_logging.ps1",
        "configuration_base64": "configuration.ps1",
    }
    for key, filename in names.items():
        value = base64.b64encode(gzip.compress((ROOT / "scripts" / filename).read_bytes(), mtime=0)).decode()
        template = template.replace("${" + key + "}", value)
    config_line = "[IO.File]::WriteAllBytes((Join-Path $root 'config.json'), [Convert]::FromBase64String('${config_base64}'))"
    assert config_line in template
    template = template.replace(config_line, "[IO.File]::WriteAllText((Join-Path $root 'config.json'), $ManualSettingsJson, [Text.UTF8Encoding]::new($false))")
    header = "#ps1_sysnative\n# Manual launch: edit ONLY nonsecret settings below, or supply ad_join_config through IMDS.\n"
    header += "$ManualSettingsJson = @'\n" + json.dumps(MANUAL_DEFAULTS, indent=2) + "\n'@\n"
    assert template.startswith("#ps1_sysnative\n")
    result = header + template[len("#ps1_sysnative\n"):]
    assert "${" not in result, "Unresolved template value"
    # Conservatively measure the encoded API metadata, not just the raw script.
    metadata = json.dumps({"user_data": base64.b64encode(result.encode()).decode()}, separators=(",", ":"))
    assert len(metadata.encode()) <= 32000, "Manual bootstrap exceeds OCI metadata limit"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(result)
    return destination


if __name__ == "__main__":
    print(package_manual())
