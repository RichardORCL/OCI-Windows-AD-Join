# Reusable IAM stack for Windows AD enrollment

Deploy this stack **once**, before creating any server stacks or [manual Cloudbase-Init instances](../../manual-cloud-init/README.md). It creates a defined-tag namespace/key, one reusable dynamic group, and a policy. It creates no Compute instance and never reads the credential secret's contents.

Upload `oci-windows-ad-iam-stack.zip` to OCI Resource Manager, or use the IAM deployment button in the repository README. Select the **allowed server compartment** and the existing Vault secret. Copy the `server_stack_settings` output to each server stack. Defaults are `ADJoinBootstrap.State=pending`. Namespace/key/value must match exactly in both stacks. Allow IAM propagation before launching servers; membership changes can take about an hour.

The matching rule includes all future servers in the selected compartment with that defined tag:

```text
ALL {instance.compartment.id = '<server-compartment-ocid>', tag.ADJoinBootstrap.State.value = 'pending'}
```

Free-form tags cannot be used for dynamic-group authorization. Do not configure this bootstrap tag as a compartment tag default: only enrollment instances should receive it.

The policy grants the group:

- Read access to the single selected Vault secret bundle.
- `{INSTANCE_READ, INSTANCE_UPDATE}` in the server compartment **only where `request.instance.id = target.instance.id`**, so each guest can update its own instance to remove its bootstrap tag.
- `use tag-namespaces` for the bootstrap namespace, as required to remove a defined tag.

The deployment identity needs permission to manage dynamic groups, policies, tag namespaces and tag definitions in the tenancy. IAM resources use a home-region provider. A dedicated, unused tag namespace is created by default. If a namespace/key already exists, import the corresponding `oci_identity_tag_namespace.bootstrap` and `oci_identity_tag.bootstrap` resources before applying, or choose another namespace. Do not deploy multiple IAM stacks with the same names; reuse this one across servers in its configured compartment.

Server-stack deployment identities also need permission to use this namespace when launching tagged instances, in addition to their Compute/network permissions. IAM administration rights are not required by the server stack. The secret and namespace are not secrets themselves; only the Vault content holds the join account/password.

## Revocation behavior

After the join, reboot and secure-channel check, the guest removes its bootstrap tag, preserving other tags and using an ETag to avoid overwriting concurrent updates. The scheduled worker then probes the selected Vault secret with a freshly issued instance-principal identity once per minute until access is denied. During propagation, a successful probe discards the returned bundle in memory without logging it. `complete` is recorded only once removal succeeded and Vault denied the probe. Cleanup retries have a separate two-hour limit.

Tag removal is eventually consistent authorization, not an immediate credential invalidation. Oracle documents about an hour for dynamic-group membership changes. Already issued identities may retain access while caches expire. Guest administrators with code execution can also use the temporary permissions and could reapply the tag before revocation. `INSTANCE_UPDATE` allows other updates to the caller's own instance; OCI does not offer a remove-only-tag permission. This pattern assumes trusted bootstrap code. For an enforced boundary against a compromised guest, move cleanup and credential delivery behind an external trusted service. Removing access cannot erase credentials already read; rotate the delegated AD join account according to your policy.

No other policy or dynamic group should independently grant these servers access to the secret. In particular, remove legacy per-instance secret policies after migrating; otherwise the revocation probe will remain authorized and the task will fail its cleanup window.

Failed or unreachable enrollment instances may retain the bootstrap tag. Administrators must remove it and verify access is revoked, or terminate those instances. Check failures explicitly; an unsuccessful cleanup never reports completion.

## Lifecycle and migration

Keep this shared IAM stack while any deployments still use it. Destroying an individual server stack does not remove shared IAM. Destroying this IAM stack removes shared authorization and retires/deletes its tag definitions as supported by OCI; first ensure all tagged enrollments are finished and review the plan.

Version 1 combined IAM and Compute in one stack. Deploy this IAM stack first and use the v2 server package for **new** server stacks. Do not blindly replace a v1 stack's source: Terraform would propose deleting its old per-instance group/policy, and first-boot user data does not rerun on an existing instance. For retained servers, review their state and grants individually; remove legacy access and any bootstrap tag only once their enrollment is complete. No live OCI migration is performed by this repository update.

## Development

```sh
terraform init
terraform validate
terraform test
```

The tests use mocked providers and do not create OCI resources. A real tenancy must validate the policies, tag removal and revocation timing.

References: [dynamic-group tag rules](https://docs.oracle.com/en-us/iaas/Content/Identity/dynamicgroups/Writing_Matching_Rules_to_Define_Dynamic_Groups.htm), [membership propagation](https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/managingdynamicgroups.htm), [Oracle's self-update policy example](https://docs.oracle.com/en-us/iaas/stack-monitoring/doc/service-requirements.html), [defined-tag permissions](https://docs.oracle.com/en-us/iaas/Content/Tagging/Tasks/managingtagsandtagnamespaces.htm).
