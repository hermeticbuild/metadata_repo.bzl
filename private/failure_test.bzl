"""Analysis tests asserting that invalid attribute combinations fail with the expected message."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//private:http.bzl", "build_metadata_purl", "verify_checksum_attrs")

def _checksum_impl(ctx):
    verify_checksum_attrs(sha256 = ctx.attr.sha256, integrity = ctx.attr.integrity, integrities = ctx.attr.integrities)
    return []

def _purl_impl(ctx):
    build_metadata_purl(
        name = "x",
        version = ctx.attr.version,
        purl_pattern = "pkg:generic/x@{version}",
        qualifiers = {"vers": "vers:semver/>=1.0.0"},
    )
    return []

_checksum_rule = rule(
    implementation = _checksum_impl,
    attrs = {"integrities": attr.string_list(), "integrity": attr.string(), "sha256": attr.string()},
)

_purl_rule = rule(
    implementation = _purl_impl,
    attrs = {"version": attr.string()},
)

def _failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, ctx.attr.expected_message)
    return analysistest.end(env)

def _make_failure_test():
    return analysistest.make(
        _failure_test_impl,
        expect_failure = True,
        attrs = {"expected_message": attr.string()},
    )

_failure_test = _make_failure_test()

def failure_tests(name):
    """Declares the failure analysis tests and a test_suite named `name`."""
    cases = {
        "integrity_multiple_values": (
            _checksum_rule,
            {"integrity": "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU= sha512-AAAA"},
            "exactly one '<algorithm>-<base64 digest>' value is supported",
        ),
        "sha256_and_integrity": (
            _checksum_rule,
            {"sha256": "00", "integrity": "sha256-AA=="},
            "Only one of 'sha256' or 'integrity' may be specified",
        ),
        "no_checksum": (
            _checksum_rule,
            {},
            "One of 'sha256', 'integrity' or 'integrities' must be specified",
        ),
        "integrities_and_sha256": (
            _checksum_rule,
            {"sha256": "00", "integrities": ["sha256-AA=="]},
            "'integrities' is mutually exclusive with 'sha256' and 'integrity'",
        ),
        "integrities_and_integrity": (
            _checksum_rule,
            {"integrity": "sha256-AA==", "integrities": ["sha512-AAAA"]},
            "'integrities' is mutually exclusive with 'sha256' and 'integrity'",
        ),
        "integrities_duplicate_algorithm": (
            _checksum_rule,
            {"integrities": ["sha256-AA==", "sha256-AAE="]},
            "Duplicate 'sha256' algorithm in integrities",
        ),
        "integrities_unsupported_only": (
            _checksum_rule,
            {"integrities": ["md5-AAAA"]},
            "None of the integrities uses an algorithm supported by Bazel",
        ),
        "integrities_multiple_in_one_entry": (
            _checksum_rule,
            {"integrities": ["sha256-AA== sha512-AAAA"]},
            "exactly one '<algorithm>-<base64 digest>' value is supported",
        ),
        "vers_and_version": (
            _purl_rule,
            {"version": "1.0"},
            "'vers' qualifier is mutually exclusive",
        ),
    }
    tests = []
    for case, (rule_, attrs, message) in cases.items():
        rule_(name = case + "_target", tags = ["manual"], **attrs)
        _failure_test(
            name = case + "_test",
            target_under_test = ":" + case + "_target",
            expected_message = message,
        )
        tests.append(":" + case + "_test")
    native.test_suite(name = name, tests = tests)
