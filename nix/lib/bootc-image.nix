# Turn a NixOS system closure into a container image that bootc can install.
#
# The shape is ostree's, not NixOS's. ostree expects the OS under /usr with
# /etc and /var as the only writable trees, a single kernel at
# /usr/lib/modules/$kver/{vmlinuz,initramfs.img}, and a set of toplevel
# symlinks pointing into /var.
#
# The one thing that makes this possible at all: bootc's container-to-ostree
# import drops any toplevel directory that is not /usr, /etc or /var *unless*
# `allow_nonusr` is set, and it sets that when the image has no ostree commit
# layer to derive from -- see `root_is_transient` in
# crates/ostree-ext/src/container/store.rs. An image built FROM scratch has no
# `ostree.diffid` label, so `base_commit` is None, so /nix survives verbatim.
# An image derived FROM an existing bootc base would have its /nix silently
# filtered out. Hence: FROM scratch, always.
{ pkgs, lib, config, bootcPackage ? pkgs.bootc }:

let
  # The same composefs-enabled ostree bootc was linked against.
  ostree = import ../pkgs/ostree-composefs.nix { inherit pkgs; };

  toplevel = config.system.build.toplevel;
  kernelPkg = config.boot.kernelPackages.kernel;
  kver = kernelPkg.modDirVersion;
  initrd = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
  kernelImage = "${kernelPkg}/${config.system.boot.loader.kernelFile}";
  dtbs = config.hardware.deviceTree.package;
  fw = "${pkgs.raspberrypifw}/share/raspberrypi/boot";

  # ostree-prepare-root reads the copy of this inside the initramfs, but bootc
  # also reads it out of /usr at install time to decide whether the root is
  # transient, so it has to exist in both places.
  prepareRootConf = pkgs.writeText "prepare-root.conf" ''
    [composefs]
    enabled = yes

    [sysroot]
    readonly = true
  '';

  # Kernel arguments bootc bakes into the BLS entry it writes. `init=` is what
  # NixOS's initrd-find-nixos-closure reads to locate the system closure, and
  # rootwait is needed because the Pi's SD controller probes late.
  kargs = pkgs.writeText "10-rpi.toml" ''
    kargs = ["rootwait", "init=${toplevel}/init"]
  '';

  # podman resolves uid 0 to find HOME, and NixOS has no build-time passwd to
  # copy: it writes /etc/passwd from an activation script, which runs after
  # install and after first boot. So ship the minimum that makes uid 0
  # resolvable during install. The users module rewrites both files at
  # activation from the deployed configuration.
  #
  # Note what is absent: /etc/shadow. It carries password hashes and this image
  # is pushable to a registry, so it must never be baked into a layer.
  minimalPasswd = pkgs.writeText "passwd" ''
    root:x:0:0:System administrator:/root:/bin/sh
    nobody:x:65534:65534:Unprivileged account:/var/empty:/bin/sh
  '';

  minimalGroup = pkgs.writeText "group" ''
    root:x:0:
    nogroup:x:65534:
  '';

  # containers/image refuses to do anything without a signature policy, and
  # looks only at ~/.config/containers/policy.json and /etc/containers/policy.json.
  # Distro images get this from the containers-common package; a NixOS closure
  # has no equivalent, so ship it.
  #
  # insecureAcceptAnything matches what every distro ships as the default.
  # Verification for bootc's own upgrades is a separate mechanism (ostree
  # signatures and the composefs digest), not this file.
  containersPolicy = pkgs.writeText "policy.json" (builtins.toJSON {
    default = [{ type = "insecureAcceptAnything"; }];
    transports.docker-daemon."" = [{ type = "insecureAcceptAnything"; }];
  });

  # /var starts empty, so the toplevel symlinks into it need their targets
  # created on first boot.
  baseDirsTmpfiles = pkgs.writeText "bootc-base-dirs.conf" ''
    d /var/home     0755 root root -
    d /var/roothome 0700 root root -
    d /var/srv      0755 root root -
    d /var/opt      0755 root root -
    d /var/mnt      0755 root root -
    d /var/usrlocal 0755 root root -
  '';

  # A config.txt fragment lifecycled with this deployment. bootc's
  # raspberry-pi backend copies it into the slot directory and config.txt
  # includes it, so per-image firmware settings travel with the image rather
  # than living on the FAT partition. A missing include is treated as blank by
  # the firmware, so an empty one is safe.
  rpiConfig = pkgs.writeText "rpi-config.txt" ''
    # Settings for this deployment. Included by config.txt from the slot
    # directory, so they are versioned with the image.
    arm_64bit=1
    enable_uart=1
    uart_2ndstage=1
    kernel=vmlinuz
    initramfs initrd followkernel
  '';

  # Everything outside /nix/store. Built as a real directory tree so that
  # /usr is a directory in the image and not a symlink into the store.
  rootTree = pkgs.runCommand "bootc-root-tree" { } ''
    set -euo pipefail
    mkdir -p $out

    # --- kernel, initramfs, device trees -------------------------------------
    kdir=$out/usr/lib/modules/${kver}
    mkdir -p "$kdir/dtbs/overlays"
    cp ${kernelImage} "$kdir/vmlinuz"
    cp ${initrd}      "$kdir/initramfs.img"
    cp ${rpiConfig}   "$kdir/rpi-config.txt"

    # modules.dep and friends: bootc's kernel lint and depmod-based tooling
    # expect the modules tree next to vmlinuz.
    cp -a ${config.system.modulesTree}/lib/modules/${kver}/. "$kdir/"
    chmod -R u+w "$kdir"
    rm -f "$kdir/build" "$kdir/source"

    # The base device trees come from the kernel, so they match it. The
    # overlays directory comes from the firmware package and is copied
    # wholesale: overlay_map.dtb and hat_map.dtb are read by the VideoCore
    # firmware itself and are not overlays, so a *.dtbo glob drops them, and
    # README has to survive or the firmware ignores os_prefix for overlays and
    # silently shares them between deployments.
    cp ${dtbs}/broadcom/bcm2712*.dtb "$kdir/dtbs/" 2>/dev/null \
      || cp ${dtbs}/bcm2712*.dtb "$kdir/dtbs/"
    cp -a ${fw}/overlays/. "$kdir/dtbs/overlays/"
    test -s "$kdir/dtbs/overlays/overlay_map.dtb"
    test -s "$kdir/dtbs/overlays/README"

    # --- the VideoCore blobs ------------------------------------------------
    # Inert on a Pi 5, whose firmware is self-contained in the SPI EEPROM, but
    # a Pi 4 needs them on the FAT partition.
    install -Dm0644 -t $out/usr/lib/raspberrypi/boot \
      ${fw}/bootcode.bin ${fw}/start*.elf ${fw}/fixup*.dat

    # --- ostree and bootc configuration -------------------------------------
    install -Dm0644 ${prepareRootConf} $out/usr/lib/ostree/prepare-root.conf
    install -Dm0644 ${kargs}           $out/usr/lib/bootc/kargs.d/10-rpi.toml

    # systemd's SwitchRoot refuses a target without an os-release, and NixOS
    # only writes /etc/os-release at activation, which is after switch-root.
    install -Dm0644 ${config.environment.etc."os-release".source} \
      $out/usr/lib/os-release

    # --- the ostree filesystem shape ----------------------------------------
    mkdir -p $out/{sysroot,var,run,proc,sys,dev,boot,usr/bin,usr/lib,bin}
    mkdir -m 1777 -p $out/tmp
    ln -s sysroot/ostree   $out/ostree
    ln -s var/roothome     $out/root
    ln -s var/home         $out/home
    ln -s var/srv          $out/srv
    ln -s var/opt          $out/opt
    ln -s var/mnt          $out/mnt
    ln -s ../var/usrlocal  $out/usr/local
    # bootc's var-run lint is fatal: /var/run must be a symlink, not a dir.
    ln -s ../run           $out/var/run

    # NixOS's activation scripts for these are forced empty in bootc.nix,
    # because they write outside /etc and /var. Bake the results instead.
    ln -s ${pkgs.bashInteractive}/bin/sh $out/bin/sh
    ln -s ${pkgs.coreutils}/bin/env      $out/usr/bin/env

    # ostree deploys /etc by three-way merge, and NixOS regenerates it at
    # activation, so a real machine-id must not be baked in.
    mkdir -p $out/etc
    echo uninitialized > $out/etc/machine-id
    chmod 0644 $out/etc/machine-id

    # podman resolves uid 0 to find HOME, and NixOS only materialises
    # /etc/passwd at activation -- which is after install and after first boot.
    # So ship the ones this system generates anyway. ostree merges /etc from
    # here and activation rewrites them later.
    #
    # passwd and group only. /etc/shadow carries password hashes and this image
    # is pushable to a registry, so it must never be baked into a layer; the
    # users module writes it at activation from the deployed configuration.
    install -Dm0644 ${minimalPasswd} $out/etc/passwd
    install -Dm0644 ${minimalGroup}  $out/etc/group
    install -Dm0644 ${containersPolicy} $out/etc/containers/policy.json

    install -Dm0644 ${baseDirsTmpfiles} \
      $out/usr/lib/tmpfiles.d/bootc-base-dirs.conf

    # A reference to the closure, so the store paths it needs end up in the
    # image. Also how anything on the running system finds the deployment.
    ln -s ${toplevel} $out/usr/lib/nixos-system
  '';
in
pkgs.dockerTools.streamLayeredImage {
  name = "nixos-rpi-bootc";
  tag = "latest";
  maxLayers = 110;

  # Nothing goes through `contents`: it symlinks each entry into / via a
  # buildEnv, which would make /usr a symlink into the store and break the
  # ostree layout. extraCommands runs in the layer root instead, where cp -a
  # produces real directories. Store paths still get their own layers because
  # streamLayeredImage includes the closure of the customisation layer, and
  # the tree above references the system closure.
  extraCommands = ''
    cp -a ${rootTree}/. ./
    chmod -R u+w ./usr ./etc
  '';

  config = {
    Labels = {
      "containers.bootc" = "1";
      "org.opencontainers.image.description" =
        "NixOS for the Raspberry Pi 5, deployable by bootc";
    };
    # bootc shells out to mkfs.fat, mkfs.ext4, ostree, skopeo and bubblewrap
    # during install, and resolves them on PATH from inside this image.
    #
    # The FHS directories at the end are not decoration. bootc re-execs itself
    # into the host's mount namespace to run `podman` (podman.rs) and `udevadm`
    # (install/baseline.rs), and those lookups inherit this PATH. A nix-only
    # PATH resolves them to store paths that do not exist on the host, which
    # fails as "Re-exec in host mountns: exec: No such file or directory".
    # Inside the image these directories hold only /bin/sh and /usr/bin/env, so
    # nothing shadows the store paths.
    Env = [
      "PATH=${lib.makeBinPath [
        bootcPackage
        ostree
        # bootc creates a container image store during install and drives it
        # with podman, resolved in-container rather than in the host mount
        # namespace, so a real podman has to be in the image.
        pkgs.podman
        pkgs.skopeo
        pkgs.bubblewrap
        pkgs.dosfstools
        pkgs.e2fsprogs
        pkgs.util-linux
        pkgs.coreutils
        pkgs.bashInteractive
        pkgs.gnugrep
        pkgs.gnused
        pkgs.jq
      ]}:/usr/bin:/bin:/usr/sbin:/sbin"
      # Without this podman falls back to a uid lookup to find HOME.
      "HOME=/root"
    ];
    Cmd = [ "${bootcPackage}/bin/bootc" ];
  };
}
