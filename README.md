# metadata_repo.bzl

Drop-in replacements for Bazel's built-in `http_archive`, `http_file`, `http_jar`
and `git_repository` repository rules additionally generating
[`@package_metadata`](https://github.com/bazel-contrib/supply-chain) targets so
external dependencies show up in SBOMs.

```starlark
bazel_dep(name = "metadata_repo.bzl", version = "...")
bazel_dep(name = "package_metadata", version = "...")  # the generated BUILD files load it

http_archive = use_repo_rule("@metadata_repo.bzl", "http_archive")

http_archive(
    name = "zlib",
    purl_pattern = "pkg:generic/zlib@{version}",
    sha256 = "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23",
    strip_prefix = "zlib-{version}",
    url = "https://github.com/madler/zlib/releases/download/v{version}/zlib-{version}.tar.gz",
    version = "1.3.1",
)
```

Requires Bazel 8.0.0 or newer.

For the `zlib` repository above, the generated targets can be inspected with:

```
bazel query --output build '@zlib//:package_metadata + @zlib//:package_metadata_integrity'
```

which prints (location comments and `generator_*` attributes omitted):

```starlark
_package_metadata(
  name = "package_metadata",
  visibility = ["//visibility:public"],
  package_metadata = [],
  attributes = ["@zlib//:package_metadata_integrity"],
  purl = "pkg:generic/zlib@1.3.1?checksum=sha256:9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23&download_url=https:%2F%2Fgithub.com%2Fmadler%2Fzlib%2Freleases%2Fdownload%2Fv1.3.1%2Fzlib-1.3.1.tar.gz&file_name=zlib-1.3.1.tar.gz",
)
_integrity(
  name = "package_metadata_integrity",
  visibility = ["//visibility:public"],
  package_metadata = [],
  values = ["sha256-mpOyt9/ax3zrpaVYpYDnRmfdb+3kWFuR7vtg8Dty3yM="],
)
```

The generated `REPO.bazel` is:

```starlark
repo(default_package_metadata = ["//:package_metadata"])
```

## Generated targets

Every repository gets, in its root package:

- `:package_metadata`: a `package_metadata` target whose PURL carries the
  [common qualifiers](https://github.com/package-url/purl-spec/blob/main/docs/common-qualifiers.md)
  `checksum`, `download_url` (first URL), `file_name` (its basename), `vcs_url`
  (`git_repository`: `git+<remote>@<commit>`) when they apply. Any other
  qualifier, such as `repository_url`, can be set through `qualifiers`.
- `:package_metadata_integrity`: an `integrity()` attribute with SRI values
  (`sha256` hex input is converted to `sha256-<base64>`).
- A `REPO.bazel` setting `default_package_metadata`, so every target in the
  repository is covered.

`http_file` and `http_jar` keep the built-in layout (`//file`, `//jar`).

## Additional attributes

| Attribute | Rules | Purpose |
| --- | --- | --- |
| `purl_pattern` (required) | all | PURL template. Tokens: `{name}`, `{version}`, `{sha256}`, `{integrity}`, `{commit}` (git), plus `substitutions`. |
| `version` | all | Used for `{version}` in `purl_pattern` and URLs. |
| `substitutions` | all | Extra `{token}` replacements. |
| `qualifiers` | all | Extra PURL qualifiers. They override the derived ones, for example `{"download_url": "https://mirror/x.tgz"}`. |
| `url_pattern` | HTTP rules | URL template with tokens. |
| `integrities` | HTTP rules | List of SRI checksums, one per algorithm (extension over the built-in rules, which only accept one `integrity`). Mutually exclusive with `sha256` and `integrity`; algorithms must be unique. Any algorithm may be listed (once each), but **Bazel only verifies the first entry whose algorithm it supports** (`sha1`, `sha256`, `sha384`, `sha512`, `blake3`) and the rule fails if none is supported; the other entries are not verified, they are only recorded. All entries populate the `checksum` PURL qualifier (comma-separated) and the `integrity()` target. `{integrity}` expands to the entry passed to Bazel. |
| `license` | all | Label of a `license()` target (from `@package_metadata//licenses`), added to the `attributes` of the generated `:package_metadata`. Resolved from your module, so the repo defining it needs a `bazel_dep`. |
| `files` | `http_archive` | Overlay files into the repository (not in native Bazel 9). |

## Token replacement

Only the attributes below are expanded; every other attribute (including
`qualifiers` values, `sha256`, `integrity`, `remote`, `commit`,
`add_prefix`, `patches` and `downloaded_file_path`) is used verbatim.

| Attribute | Rules | Available tokens |
| --- | --- | --- |
| `purl_pattern` | all | HTTP rules: `{name}`, `{version}`, `{sha256}`, `{integrity}`; `git_repository`: `{name}`, `{version}`, `{commit}`; plus `substitutions` |
| `url`, `urls`, `url_pattern` | `http_archive`, `http_file`, `http_jar` | `{name}`, `{version}`, `{sha256}`, `{integrity}`, plus `substitutions` |
| `strip_prefix` | `http_archive` | same as `url` |
| `tag`, `branch` | `git_repository` | `{name}`, `{version}`, plus `substitutions` (not `{commit}`: it is resolved from the tag) |

- `{name}` is the repository name, `{version}` the `version` attribute (empty
  if unset), `{commit}` the resolved commit of a `git_repository`.
- `substitutions` maps custom tokens (keys include the braces, for example
  `"{owner}": "bazelbuild"`) to their values. The values themselves are not expanded.
- Unknown tokens are left as is.

## SBOM generation

Use the SBOM rules from `@supply_chain_tools//sbom`. The aspect only collects
metadata from **rule targets** (through `applicable_licenses`), never from
source files. A target that depends directly on `@zlib//:zlib.h` exposes no
metadata. Depend on a rule target instead, for example a `filegroup`:

- The default generated BUILD file already contains `filegroup(name = "all_files")`.
- If you pass `build_file` or `build_file_content`, define your own rule targets
  (for example a `filegroup`); the metadata is applied to them automatically.

The `integrity()` rule and the SBOM tools are not yet in a release of
`package_metadata` / `supply_chain_tools`; the test module pins them with a
`git_override`.

## Tests

`tests/` is a separate Bazel module that depends on this one through
`local_path_override`. It fetches real artifacts and checks:

- PURL, checksum and integrity output for each rule and attribute combination;
- that the extracted repositories are byte-identical to those of the built-in
  rules (`diff_test` over a file listing with checksums);
- CycloneDX and SPDX output.

```sh
cd tests && bazel test //...
```

Verified with Bazel 8.x, 9.x and 10.0.0rc2.
