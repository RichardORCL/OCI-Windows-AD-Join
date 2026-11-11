# Manual OCI Windows launch with Cloudbase-Init

This model launches a Windows server through OCI's normal **Create instance** workflow, without a Resource Manager server stack. Attach the single self-contained [oci-windows-ad-cloud-init.ps1](oci-windows-ad-cloud-init.ps1) file as the initialization script. It embeds the same join worker, SDK setup, timing logs and access cleanup used by the Resource Manager model.

Windows uses **Cloudbase-Init PowerShell**, not Linux `#cloud-config` YAML. Keep `#ps1_sysnative` as the first line. The script installs the OCI Python SDK with `--no-compile`; it is not a way to eliminate the SDK dependency.

## Prerequisites

1. Create/reuse the shared [IAM setup](../RMS/iam/README.md) first, either through its IAM stack or equivalent administrator-created resources. It grants the tagged instance access to one credential secret and self-only permissions to remove its bootstrap tag.
2. Use an unjoined OCI Windows platform image with Cloudbase-Init and its Python/pip runtime. Existing AD, DNS, routing, firewall and outbound API/PyPI prerequisites are the same as the [server stack](../RMS/README.md#prerequisites).
3. Launch in the IAM setup's allowed server compartment and use a Vault secret in the instance's region.
4. **Apply the bootstrap defined tag at instance creation:** by default namespace `ADJoinBootstrap`, key `State`, value `pending`. It must exactly match the shared IAM setup. The script checks its presence before trying Vault; it cannot grant itself the initial access. The launching user needs permission to use that tag namespace.

A Vault **secret OCID** is needed, not just a Vault OCID. The secret OCID is a nonsecret pointer and must be provided in the script settings or metadata; it cannot be discovered from inside the secret it identifies.

## Option A: configure the attached script

Download the `.ps1` file and edit its `$ManualSettingsJson` section near the top. Keep `manual_metadata` set to `true`. For example, set these nonsecret fields:

```json
{
  "secret_id": "ocid1.vaultsecret.oc1.eu-amsterdam-1.REPLACE",
  "domain": "corp.example.com",
  "computer_name": "OCI-WIN01",
  "override_dns": true,
  "dns_servers": ["10.0.0.10", "10.0.0.11"],
  "ou_path": "OU=Servers,DC=corp,DC=example,DC=com",
  "config_from_vault": false
}
```

The file already includes the default tag settings. Leave `computer_name` empty to retain the unique Windows name assigned to the VM. Use a unique 1–15 character name if you specify one. Region is derived automatically from IMDSv2.

Create the instance normally, selecting its shape, Windows version and existing network. In the Tags section add the bootstrap defined tag. In the initialization-script section choose/upload your edited `.ps1` file. Use IMDSv2 and disable legacy metadata endpoints. There is no Terraform plan or server stack for this launch.

With this option the secret contains only the credential JSON:

```json
{"username":"join-service@corp.example.com","password":"REPLACE_WITH_REAL_PASSWORD"}
```

Never put the username/password into the script or instance metadata. Only Vault holds credential values. Base64/gzip packaging is not encryption, and launch-time `user_data` cannot be removed or changed afterward.

## Option B: supply settings through metadata

Use the unedited script and put configuration under the `ad_join_config` metadata key. Its value may be a JSON object (extended metadata), or a JSON-encoded string (ordinary metadata). That object's fields override the editable script settings. Other instance metadata fields are ignored.

[extended-metadata.example.json](extended-metadata.example.json) shows the full nonsecret configuration. [metadata.example.json](metadata.example.json) shows a compact pointer that selects the Vault-profile mode described below. [config.example.json](config.example.json) is the settings object without an outer metadata wrapper.

If your Console does not expose arbitrary metadata fields, use Option A, or launch through the OCI CLI/API. For example, from this folder, after replacing placeholders in the files and command:

```sh
oci compute instance launch \
  --compartment-id '<allowed-server-compartment-ocid>' \
  --availability-domain '<availability-domain>' \
  --display-name 'windows-ad-member' \
  --shape 'VM.Standard.E4.Flex' \
  --shape-config '{"ocpus":2,"memoryInGBs":16}' \
  --source-details '{"sourceType":"image","imageId":"<compatible-windows-image-ocid>"}' \
  --subnet-id '<subnet-ocid>' \
  --assign-public-ip false \
  --instance-options '{"areLegacyImdsEndpointsDisabled":true}' \
  --defined-tags file://defined-tags.example.json \
  --extended-metadata file://extended-metadata.example.json \
  --user-data-file oci-windows-ad-cloud-init.ps1
```

Use `--metadata file://metadata.example.json` instead of `--extended-metadata` for the compact JSON-string example. Do not set the same custom key in both metadata maps. The CLI is used on your workstation for this example; it is not installed in the VM. The supplied image OCID must be a compatible Windows image for your selected region/shape.

## Option C: also load AD and DNS settings from Vault

Set `config_from_vault` to the JSON boolean `true` in the script header or metadata, and use a secret in the format of [vault-secret.example.json](vault-secret.example.json):

```json
{
  "username": "join-service@corp.example.com",
  "password": "REPLACE_WITH_REAL_PASSWORD",
  "ad_join": {
    "domain": "corp.example.com",
    "override_dns": true,
    "dns_servers": ["10.0.0.10", "10.0.0.11"],
    "ou_path": "OU=Servers,DC=corp,DC=example,DC=com"
  }
}
```

The `ad_join` object replaces the AD domain/OU/DNS settings from the script or metadata. The per-instance computer name, tag namespace/key/value and secret OCID remain bootstrap settings. `override_dns` must be a JSON boolean, not the string `"false"`. DNS servers may be an IPv4 array or comma-separated string; an enabled override requires at least one valid address.

In this mode, initial subnet/DHCP DNS must resolve OCI authentication/Secrets and PyPI names: the worker installs the SDK and retrieves the Vault profile **before** changing DNS. It then applies domain DNS and resolves AD SRV records **before** calling `Add-Computer`. The selected domain DNS must also resolve OCI endpoints so post-join cleanup can work.

Only an allowlisted nonsecret configuration snapshot is written to `C:\ProgramData\OCI-ADJoin\config.json` for use after reboot. Credentials pass through memory only. Metadata is resolved once, and a successful Vault profile is cached as nonsecret settings; subsequent changes to metadata/profile settings do not reconfigure an already initialized VM. Credential reads still use the secret's CURRENT version. Use a new VM for a different domain or enrollment configuration.

## Timing, logs and cleanup

The first task run starts after 30 seconds. It checks Cloudbase-Init readiness every 15 seconds while polling, retries at one-minute intervals, and schedules the domain-join reboot with a ten-second delay. The worker never reboots while Cloudbase-Init is active.

```powershell
Get-Content C:\ProgramData\OCI-ADJoin\status.json
Get-Content C:\ProgramData\OCI-ADJoin\worker.log -Tail 50
Get-Content C:\ProgramData\OCI-ADJoin\sdk-install.log -Tail 50 -ErrorAction SilentlyContinue
Get-Content C:\ProgramData\OCI-ADJoin\timings.jsonl |
    ForEach-Object { $_ | ConvertFrom-Json } |
    Where-Object { $_.event -eq 'stage_end' } |
    Select-Object stage, outcome, duration_ms, run_id
```

After the join/reboot/secure-channel check, the worker removes its bootstrap tag and probes Vault until a fresh request is denied. Final status is `complete`, stage `domain-verified-tag-removed-vault-denied`. IAM membership revocation can take about an hour, and existing issued identities may remain authorized while caches expire. Guest administrators could reapply the tag during temporary self-update access; this model assumes trusted bootstrap code. Failed/unreachable instances may retain the tag and require administrator cleanup. See the [shared IAM guide](../RMS/iam/README.md#revocation-behavior) for these limits.

## Build and test

The generated file runs independently of the repository. Rebuilding it uses shared runtime sources in `../RMS/scripts/` so fixes remain consistent between the manual and Resource Manager models:

```sh
python3 manual-cloud-init/build.py
python3 -m unittest discover -s manual-cloud-init/tests -p 'test_*.py'
pwsh -NoProfile -File manual-cloud-init/tests/test_configuration.ps1
```

Run these commands from the repository root. Commit the generated `.ps1` together with source changes. Build validation checks that the complete encoded script plus example metadata fits OCI's metadata limit. Actual Windows launch, Vault/IAM enforcement and domain join require testing in your tenancy.

References: [OCI Windows Cloudbase-Init](https://docs.oracle.com/en-us/iaas/Content/Compute/References/images.htm), [IMDSv2](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/gettingmetadata.htm), [metadata updates and reserved keys](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/updatinginstancemetada.htm).
