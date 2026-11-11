import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("cleanup_access", ROOT / "scripts/cleanup_access.py")
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)


class ServiceError(Exception):
    def __init__(self, status):
        self.status = status


class AccessCleanupTest(unittest.TestCase):
    def setUp(self):
        self.config = {"region": "eu-amsterdam-1", "secret_id": "secret", "tag_namespace": "ADJoinBootstrap", "tag_key": "State"}
        self.oci = MagicMock()
        self.oci.exceptions.ServiceError = ServiceError
        self.oci.core.models.UpdateInstanceDetails.side_effect = lambda **kw: SimpleNamespace(**kw)
        self.compute = self.oci.core.ComputeClient.return_value
        self.secrets = self.oci.secrets.SecretsClient.return_value
        self.signer = object()

    def instance(self, tags, etag="version1"):
        return SimpleNamespace(data=SimpleNamespace(defined_tags=tags), headers={"etag": etag})

    @patch.object(cleanup, "metadata", return_value={"id": "self-instance"})
    def test_remove_only_bootstrap_key_and_preserve_other_tags(self, _):
        tags = {"ADJoinBootstrap": {"State": "pending", "Other": "keep"}, "Operations": {"Owner": "keep"}}
        self.compute.get_instance.return_value = self.instance(tags)
        self.compute.update_instance.return_value = self.instance({"ADJoinBootstrap": {"Other": "keep"}, "Operations": {"Owner": "keep"}})
        cleanup.remove_tag(self.oci, self.config, self.signer)
        args, kw = self.compute.update_instance.call_args
        self.assertEqual(args[0], "self-instance")
        self.assertEqual(args[1].defined_tags, {"ADJoinBootstrap": {"Other": "keep"}, "Operations": {"Owner": "keep"}})
        self.assertEqual(kw["if_match"], "version1")
        self.assertEqual(tags["ADJoinBootstrap"]["State"], "pending")

    @patch.object(cleanup, "metadata", return_value={"id": "self-instance"})
    def test_missing_tag_is_idempotent(self, _):
        self.compute.get_instance.return_value = self.instance({"Operations": {"Owner": "keep"}})
        cleanup.remove_tag(self.oci, self.config, self.signer)
        self.compute.update_instance.assert_not_called()

    @patch.object(cleanup, "metadata", return_value={"id": "self-instance"})
    def test_etag_conflict_reloads_and_preserves_concurrent_change(self, _):
        self.compute.get_instance.side_effect = [
            self.instance({"ADJoinBootstrap": {"State": "pending"}}),
            self.instance({"ADJoinBootstrap": {"State": "pending"}, "Ops": {"New": "keep"}}, "version2"),
        ]
        self.compute.update_instance.side_effect = [ServiceError(412), self.instance({"Ops": {"New": "keep"}})]
        cleanup.remove_tag(self.oci, self.config, self.signer)
        args, kw = self.compute.update_instance.call_args
        self.assertEqual(args[1].defined_tags, {"Ops": {"New": "keep"}})
        self.assertEqual(kw["if_match"], "version2")

    @patch.object(cleanup, "metadata", return_value={"id": "self-instance", "definedTags": {}})
    def test_previous_cleanup_recovers_after_api_access_is_revoked(self, _):
        self.compute.get_instance.side_effect = ServiceError(404)
        cleanup.remove_tag(self.oci, self.config, self.signer)
        self.compute.update_instance.assert_not_called()

    @patch.object(cleanup, "metadata", return_value={"id": "self-instance"})
    def test_missing_metadata_tags_are_not_proof_of_cleanup(self, _):
        self.compute.get_instance.side_effect = ServiceError(404)
        with self.assertRaises(ServiceError):
            cleanup.remove_tag(self.oci, self.config, self.signer)

    @patch.object(cleanup, "metadata", return_value={"id": "self-instance"})
    def test_successful_response_with_tag_still_present_is_failure(self, _):
        self.compute.get_instance.return_value = self.instance({"ADJoinBootstrap": {"State": "pending"}})
        self.compute.update_instance.return_value = self.compute.get_instance.return_value
        with self.assertRaises(RuntimeError):
            cleanup.remove_tag(self.oci, self.config, self.signer)

    def test_vault_denial_is_required_for_completion(self):
        for status in (403, 404):
            with self.subTest(status=status):
                self.secrets.get_secret_bundle.side_effect = ServiceError(status)
                self.assertEqual(cleanup.verify_revocation(self.oci, self.config, self.signer), 0)

    def test_still_authorized_remains_pending(self):
        self.assertEqual(cleanup.verify_revocation(self.oci, self.config, self.signer), 10)

    def test_transient_or_authentication_errors_do_not_prove_revocation(self):
        for error in (ServiceError(401), ServiceError(429), ServiceError(500), TimeoutError()):
            with self.subTest(error=type(error), status=getattr(error, "status", None)):
                self.secrets.get_secret_bundle.side_effect = error
                with self.assertRaises(type(error)):
                    cleanup.verify_revocation(self.oci, self.config, self.signer)


if __name__ == "__main__":
    unittest.main()
