"""Versioned research fixture validation, not an Arena parser or journal codec."""

import base64
import hashlib
import json
import pathlib


def validate(manifest, portable=True):
    def require(condition, message):
        if not condition:
            raise ValueError(message)

    require(
        manifest["schema"] == "arena-suite.fixture/1", "unsupported fixture version"
    )
    provenance = manifest["provenance"]
    require(
        provenance in {"synthetic", "sanitized_capture", "private_exact_capture"},
        "unknown provenance",
    )
    require(
        not portable or provenance != "private_exact_capture",
        "private fixture cannot enter portable corpus",
    )
    for field in (
        "id",
        "scenario",
        "source",
        "observation_layer",
        "clock",
        "adapter_version",
        "parser_version",
    ):
        require(
            isinstance(manifest[field], str) and bool(manifest[field]),
            "missing " + field,
        )
    require(isinstance(manifest["expected_associations"], list), "missing associations")
    transformations = manifest["transformations"]
    require(isinstance(transformations, list), "invalid transformations")
    if provenance == "sanitized_capture":
        require(
            bool(transformations) and manifest["fidelity"] == "transformed",
            "sanitized bytes are transformed",
        )
        require(
            bool(manifest["authorization_reference"])
            and bool(manifest["review_reference"]),
            "capture review missing",
        )
        for item in transformations:
            require(
                all(
                    isinstance(item.get(k), str) and item[k]
                    for k in ("scope", "reason", "policy", "mapping")
                ),
                "transformation metadata missing",
            )
    if provenance == "private_exact_capture":
        require(
            not transformations and manifest["fidelity"] == "exact_at_declared_layer",
            "false exactness",
        )
    if provenance == "synthetic":
        require(
            manifest["fidelity"] == "synthetic", "synthetic data is not live evidence"
        )
    offsets, ticks, bodies = {}, {}, {}
    require(bool(manifest["units"]), "empty fixture")
    for unit in manifest["units"]:
        stream = unit["stream"]
        require(isinstance(stream, str) and bool(stream), "invalid stream")
        require(
            type(unit["offset"]) is int and unit["offset"] == offsets.get(stream, 0),
            "offset gap/overlap",
        )
        require(
            type(unit["ticks"]) is int and unit["ticks"] >= ticks.get(stream, 0),
            "invalid clock order",
        )
        data = base64.b64decode(unit["base64"], validate=True)
        require(
            hashlib.sha256(data).hexdigest() == unit["sha256"],
            "payload digest mismatch",
        )
        offsets[stream] = unit["offset"] + len(data)
        ticks[stream] = unit["ticks"]
        bodies.setdefault(stream, bytearray()).extend(data)
    require(set(bodies) == set(manifest["stream_sha256"]), "stream inventory mismatch")
    for stream, body in bodies.items():
        require(
            hashlib.sha256(body).hexdigest() == manifest["stream_sha256"][stream],
            "stream digest mismatch",
        )
    return bodies


if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parents[2] / "Fixtures"
    count = 0
    for path in sorted(root.rglob("*.fixture.json")):
        validate(json.loads(path.read_text()))
        count += 1
    if not count:
        raise ValueError("No fixtures found")
    print(
        f"Validated {count} portable fixture(s); metadata validation is NOT a secret scan"
    )
