# OCI Windows AD Join

Launch Windows Server on Oracle Cloud Infrastructure and join an existing Active Directory domain using temporary OCI Vault access. Deploy shared IAM once, then reuse it for each new server.

## 1. Create shared IAM once

[![Deploy IAM to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/RichardORCL/OCI-Windows-AD-Join/raw/refs/heads/main/RMS/dist/oci-windows-ad-iam-stack.zip)

The [IAM stack](RMS/iam/README.md) creates a dedicated defined-tag namespace/key, one reusable dynamic group, and scoped policies. Select the server compartment and an existing Vault secret. Copy its `server_stack_settings` output for use below. Allow time for IAM propagation before the first launch.

Create the Vault secret in the server deployment region using **Plain-Text** content with JSON for a delegated AD join account:

```json
{"username":"join-service@corp.example.com","password":"REPLACE_WITH_REAL_PASSWORD"}
```

This step requires tenancy IAM/tag administration permissions. The group is restricted to the selected compartment and the bootstrap defined tag, defaulting to `ADJoinBootstrap.State=pending`.

## 2. Launch a server for each enrollment

[![Deploy Server to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/RichardORCL/OCI-Windows-AD-Join/raw/refs/heads/main/RMS/dist/oci-windows-ad-stack.zip)

The [server stack](RMS/README.md) creates the instance with the temporary tag. It creates no IAM resources. Match the IAM stack's server compartment, secret OCID and tag namespace/key/value exactly. The deployment identity needs Compute/network permissions and permission to use the tag namespace.

The setup form includes:

- Windows Server 2019, 2022 or 2025 and an x86 Standard Flex shape selector.
- Instance/computer name, OCPUs, memory, boot volume, availability domain and existing VCN/subnet.
- Optional NSGs as comma-separated OCIDs; blank attaches none.
- AD domain, OU, Vault secret and bootstrap tag settings.
- **Override DNS servers before AD join**: apply domain DNS IPv4 addresses and clear the DNS cache before domain discovery and joining. Unchecked retains subnet/DHCP DNS.

Defaults are a private instance, 2 OCPUs, 16 GiB RAM and a 100 GiB boot volume. Shape availability, capacity and Windows licensing charges depend on OCI. Your subnet must reach AD/DC DNS, regional OCI authentication/Compute/Secrets APIs and PyPI for SDK installation; see the detailed guide for routes, firewalls and prepared-image options.

## Temporary secret access

The guest retrieves the join username/password directly from Vault using instance-principal authentication. Credential values never enter Terraform state, outputs or user data.

After joining and rebooting, the scheduled worker verifies the AD secure channel, removes its bootstrap tag and probes Vault until access is denied. Terraform ignores subsequent defined-tag changes so it does not restore the tag. Unrelated tags are preserved. Each guest can update only its own instance; it cannot update another enrollment server.

**Tag-based revocation is eventual:** OCI documents about an hour for dynamic-group membership changes. The worker reports `revocation_pending` while Vault is still readable and marks `complete` only after tag removal and a fresh denied Vault call. Successful probes during propagation discard their bundles without logging. Existing issued identities may remain authorized while caches expire. Cleanup retries have a separate two-hour limit. [Oracle propagation guidance](https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/managingdynamicgroups.htm).

Bootstrap code must be trusted: a guest administrator could reapply the tag while its temporary self-update permission remains. Revocation also cannot erase already retrieved credentials. See the [IAM security and migration guide](RMS/iam/README.md) for these limits and handling failed enrollments or legacy per-instance policies.

## Check the result

A successful Terraform Apply confirms infrastructure provisioning. Inspect the guest:

```powershell
Get-Content C:\ProgramData\OCI-ADJoin\status.json
Get-CimInstance Win32_ComputerSystem | Select-Object Name, Domain, PartOfDomain
Test-ComputerSecureChannel
```

Final status is `complete`, stage `domain-verified-tag-removed-vault-denied`. Failures during tag removal or revocation checking remain incomplete and require attention. Delete/terminate failed enrollment instances or remove their bootstrap tags administratively. Keep shared IAM until no further server deployments need it.

## Repository and development

| Path | Contents |
| --- | --- |
| [`RMS/iam/`](RMS/iam/) | Shared IAM stack, YAML form and offline tests |
| [`RMS/`](RMS/) | Server Terraform stack and YAML form |
| [`RMS/scripts/`](RMS/scripts/) | Windows bootstrap, Vault reader, access cleanup and packaging |
| [`RMS/tests/`](RMS/tests/) | Server plans and Python credential/cleanup/package tests |
| [`RMS/dist/`](RMS/dist/) | Separate upload-ready IAM and server ZIPs used by the buttons |

Rebuild both deployment archives after source changes, and commit them with the sources:

```sh
python3 RMS/scripts/package_stack.py
terraform -chdir=RMS init
terraform -chdir=RMS test
terraform -chdir=RMS/iam init
terraform -chdir=RMS/iam test
python3 -m unittest discover -s RMS/tests -p 'test_*.py'
```

Deployment requires Terraform >=1.2; mocked plan tests require >=1.7. Offline tests create no OCI resources. Both forms are checked against Oracle's published Resource Manager schema. Live Windows boot, policy enforcement and revocation timing still need validation in your tenancy.

Existing version 1 stacks retain their old source. Deploy the new shared IAM stack and use the server package for new stacks; review the [migration guidance](RMS/iam/README.md#lifecycle-and-migration) before changing retained stacks. No live OCI resources are changed by this repository update.

Maintainer: [RichardORCL](https://github.com/RichardORCL).
