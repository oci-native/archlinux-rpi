# ostree with composefs support compiled in.
#
# nixpkgs builds ostree without --with-composefs, so a deployment that asks for
# it fails at checkout time with:
#
#   composefs: enabled at runtime, but support is not compiled in
#
# prepare-root.conf in this image sets [composefs] enabled = yes, which is not
# optional here: it is what makes the deployment root a read-only image, which
# is exactly the property a /nix/store wants.
#
# The same derivation has to be used for bootc's buildInputs and for the
# ostree in the image, or the binary links one libostree and runs against
# another.
{ pkgs }:

pkgs.ostree.overrideAttrs (old: {
  buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.composefs ];
  configureFlags = (old.configureFlags or [ ]) ++ [ "--with-composefs" ];
})
