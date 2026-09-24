import base64
import copy
import hashlib
import json
import pathlib
import random
import unittest
from fixture_manifest import validate

ROOT = pathlib.Path(__file__).resolve().parents[2]


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(
            (ROOT / "Fixtures/Synthetic/opaque.fixture.json").read_text()
        )

    def test_rejects_corruption_gaps_versions_and_private_export(self):
        for field, value in (("offset", 1), ("sha256", "0" * 64), ("ticks", -1)):
            bad = copy.deepcopy(self.manifest)
            bad["units"][0][field] = value
            with self.assertRaises(ValueError):
                validate(bad)
        for field, value in (
            ("schema", "future/2"),
            ("provenance", "private_exact_capture"),
            ("fidelity", "exact_at_declared_layer"),
        ):
            bad = copy.deepcopy(self.manifest)
            bad[field] = value
            with self.assertRaises(ValueError):
                validate(bad)

    def test_sanitized_capture_requires_transformation_and_review(self):
        self.manifest["provenance"] = "sanitized_capture"
        self.manifest["fidelity"] = "transformed"
        self.manifest["authorization_reference"] = "test-only-authorization"
        self.manifest["review_reference"] = "test-only-review"
        with self.assertRaises(ValueError):
            validate(self.manifest)
        self.manifest["transformations"] = [
            {
                "scope": "body",
                "reason": "test replacement",
                "policy": "test/1",
                "mapping": "test source -> export",
            }
        ]
        validate(self.manifest)

    def test_opaque_bytes_survive_all_splits_and_200_seeded_partitions(self):
        body = bytes(validate(self.manifest)["synthetic-stream"])
        rng = random.Random(0)
        partitions = [[i] for i in range(len(body) + 1)]
        partitions += [list(range(len(body) + 1)), []]
        partitions += [
            sorted(rng.sample(range(len(body) + 1), rng.randrange(len(body) + 2)))
            for _ in range(200)
        ]
        for boundaries in partitions:
            fixture = copy.deepcopy(self.manifest)
            fixture["units"] = []
            points = [0] + boundaries + [len(body)]
            for ticks, (start, end) in enumerate(zip(points, points[1:])):
                data = body[start:end]
                fixture["units"].append(
                    {
                        "stream": "synthetic-stream",
                        "offset": start,
                        "ticks": ticks,
                        "base64": base64.b64encode(data).decode(),
                        "sha256": hashlib.sha256(data).hexdigest(),
                    }
                )
            self.assertEqual(validate(fixture)["synthetic-stream"], body)


if __name__ == "__main__":
    unittest.main()
