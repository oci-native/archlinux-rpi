# Resume after reboot

## State
- Pushed through `4f0e5e7`. One local commit not yet pushed: `6921a8e`
  (held back deliberately -- the workflow has `cancel-in-progress: true`,
  so pushing kills the running CI build).
- CI run `34629936972` was building the 50G unprovisioned image.
- Nothing was ever written to /dev/sdb or any physical device.

## The blocker, solved
`bootc install to-disk` cannot run on this x86_64 host. It calls
`setns(/proc/1/ns/mnt, CLONE_NEWNS)`, which the kernel refuses with
EINVAL from any multithreaded process, and qemu-user always carries an
extra RCU thread. Measured: the same single-threaded `grep` reports
`Threads: 1` natively and `Threads: 2` emulated. No podman flag fixes it.
CI builds the image natively on arm64; provisioning happens here.

## Next steps
1. Check CI finished green:
       gh run list --limit 1
2. Push the held commit:
       git push origin main
3. Download + restore the 50G image:
       cd .ci-artifact
       gh run download <run-id> -n rpi-bootc-unprovisioned-img
       zstd -d --sparse rpi-bootc.img.zst -o rpi-bootc.img
       truncate -s 50G rpi-bootc.img
       stat -c%s rpi-bootc.img      # expect 53687091200
4. Provision it locally (the only place secrets.env exists):
       cd /var/home/bupd/code/rpi
       sudo ./scripts/rpi-disk-image/provision-image.sh \
           .ci-artifact/rpi-bootc.img ./secrets.env
   Expect 16 OK lines, no FAIL.
5. Flash -- Prasanth runs this, never the agent. Confirm the device first
   with `lsblk`; /dev/sdb was the 59.5G USB card holding the old NixOS
   citadel install, and flashing destroys it.
