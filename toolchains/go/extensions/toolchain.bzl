"""Go toolchain module extension with flake support."""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@bazel_skylib//lib:sets.bzl", "sets")
load("@rules_nixpkgs_core//:nixpkgs.bzl", "nixpkgs_local_repository")
load("//:go.bzl", "nixpkgs_go_configure")

_ISOLATED_OR_ROOT_ONLY_ERROR = "Illegal use of the {tag_name} tag. The {tag_name} tag may only be used on an isolated module extension or in the root module or rules_nixpkgs_go."

def _flake_toolchain(flake):
    # Create nixpkgs repository from flake
    nix_file_content = """
let
  lock = builtins.fromJSON (builtins.readFile ./{});
  src = lock.nodes.nixpkgs.locked;
  nixpkgs =
    if src.type == "github" then
      fetchTarball {{
        url = "https://github.com/${{src.owner}}/${{src.repo}}/archive/${{src.rev}}.tar.gz";
        sha256 = src.narHash;
      }}
    else if src.type == "tarball" then
      fetchTarball {{
        url = src.url;
        sha256 = src.narHash;
      }}
    else
      abort "Unsupported nixpkgs source type: ${{src.type}}";
in
import nixpkgs
""".format(flake.lock_file.name)

    # Create the nixpkgs repository
    nixpkgs_repo_name = flake.name + "_nixpkgs"
    nixpkgs_local_repository(
        name = nixpkgs_repo_name,
        nix_file_content = nix_file_content,
        nix_file_deps = [flake.lock_file],
    )
    
    # Configure the Go toolchain using the created repository
    # Note: register=False because module extensions can't call native.register_toolchains
    nixpkgs_go_configure(
        sdk_name = flake.name,
        repository = "@" + nixpkgs_repo_name,
        attribute_path = flake.attribute_path,
        register = False,  # Module extensions can't register toolchains
        rules_go_repo_name = flake.rules_go_repo_name,
    )

_OVERRIDE_TAGS = {
    "flake": _flake_toolchain,
}

def _go_toolchain_impl(module_ctx):
    all_repos = sets.make()
    root_deps = sets.make()
    root_dev_deps = sets.make()

    is_isolated = getattr(module_ctx, "is_isolated", False)

    # Handle toolchain configuration tags
    for mod in module_ctx.modules:
        module_repos = sets.make()
        
        is_root = mod.is_root
        is_core = mod.name == "rules_nixpkgs_go"
        may_override = is_isolated or is_root or is_core

        for tag_name, tag_fun in _OVERRIDE_TAGS.items():
            for tag in getattr(mod.tags, tag_name):
                is_dev_dep = module_ctx.is_dev_dependency(tag)

                if not may_override:
                    fail(_ISOLATED_OR_ROOT_ONLY_ERROR.format(tag_name = tag_name))

                if sets.contains(module_repos, tag.name):
                    fail("Duplicate toolchain name '{}' in module '{}'".format(tag.name, mod.name))
                else:
                    sets.insert(module_repos, tag.name)

                if is_root:
                    if is_dev_dep:
                        sets.insert(root_dev_deps, tag.name + "_toolchains")
                    else:
                        sets.insert(root_deps, tag.name + "_toolchains")

                if not sets.contains(all_repos, tag.name):
                    sets.insert(all_repos, tag.name)
                    tag_fun(tag)

    return module_ctx.extension_metadata(
        root_module_direct_deps = sets.to_list(root_deps),
        root_module_direct_dev_deps = sets.to_list(root_dev_deps),
    )

_NAME_ATTRS = {
    "name": attr.string(
        doc = "A unique name for this Go toolchain.",
        mandatory = True,
    ),
}

_FLAKE_ATTRS = {
    "lock_file": attr.label(
        doc = "The flake.lock file.",
        mandatory = True,
        allow_single_file = True,
    ),
    "attribute_path": attr.string(
        doc = "The nixpkgs attribute path for the Go toolchain.",
        default = "go",
    ),
    "register": attr.bool(
        doc = "Whether to automatically register the toolchain.",
        default = True,
    ),
    "rules_go_repo_name": attr.string(
        doc = "The name of the rules_go repository.",
        default = "io_bazel_rules_go",  # This matches the repo_name in MODULE.bazel
    ),
}

_flake_tag = tag_class(
    attrs = dicts.add(_NAME_ATTRS, _FLAKE_ATTRS),
    doc = "Configure a Go toolchain from a flake.lock file.",
)

go_toolchain = module_extension(
    _go_toolchain_impl,
    tag_classes = {
        "flake": _flake_tag,
    },
)