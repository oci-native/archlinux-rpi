# archlinuxarm-docker (vendored)

Dockerfile copied verbatim from [arch4edu/archlinuxarm-docker](https://github.com/arch4edu/archlinuxarm-docker).
Wraps `http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz` into an OCI image.
Nothing less, nothing more.

Vendored instead of pulled from Docker Hub so the Arch variants build from a base
image this repo controls, same spirit as the AlmaLinux variants pulling their
`repos` stage from official quay.io images.

Build it once before building any `*-arch` variant:

```bash
make archlinuxarm-base
```

That downloads the upstream tarball into this directory and tags the result
`localhost/archlinuxarm:latest`, which `10-kitten-rpi-arch/Containerfile` builds from.
