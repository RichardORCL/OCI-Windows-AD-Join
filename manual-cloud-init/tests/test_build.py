import base64
import gzip
import importlib.util
import json
from pathlib import Path
import re
import tempfile
import unittest

MANUAL = Path(__file__).resolve().parent.parent
RUNTIME = MANUAL.parent / "RMS/scripts"
spec = importlib.util.spec_from_file_location("manual_build", MANUAL / "build.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class ManualBuildTest(unittest.TestCase):
    def test_single_file_contains_exact_shared_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            script = builder.package_manual(Path(directory) / "bootstrap.ps1").read_text()
        self.assertTrue(script.startswith("#ps1_sysnative\n"))
        self.assertNotIn("${", script)
        files = dict(re.findall(r"Write-BootstrapFile '([^']+)' '([A-Za-z0-9+/=]+)'", script))
        self.assertEqual(set(files), {"join-domain.ps1", "configuration.ps1", "read_secret.py", "cleanup_access.py", "stage_logging.ps1"})
        for name, payload in files.items():
            self.assertEqual(gzip.decompress(base64.b64decode(payload)), (RUNTIME / name).read_bytes())

    def test_checked_in_script_is_current_and_metadata_fits(self):
        with tempfile.TemporaryDirectory() as directory:
            result = builder.package_manual(Path(directory) / "bootstrap.ps1")
            self.assertEqual(result.read_bytes(), (MANUAL / "oci-windows-ad-cloud-init.ps1").read_bytes())
            metadata = {"user_data": base64.b64encode(result.read_bytes()).decode()}
            extended = json.loads((MANUAL / "extended-metadata.example.json").read_text())
            self.assertLessEqual(len(json.dumps({"metadata": metadata, "extendedMetadata": extended}).encode()), 32000)


if __name__ == "__main__":
    unittest.main()
