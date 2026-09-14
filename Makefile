PODMAN = sudo podman

IMAGE_NAME = almalinux-bootc-rpi
VERSION_MAJOR = 10
PLATFORM = linux/amd64
VARIANT = general
LABELS ?=
# Optional podman build memory cap. Left unset by default (no behavior change
# for existing variants); set when the host is memory-constrained so a build
# that outgrows its budget dies with a clear OOM in its own log instead of
# getting silently killed by the host's cgroup limits.
MEMORY ?=
MEMORY_SWAP ?=

ifeq ($(VARIANT), general)
    SUFFIX =
else
    SUFFIX = -$(VARIANT)
endif

.ONESHELL:
.PHONY: all
all: image rechunk

.PHONY: archlinuxarm-base
archlinuxarm-base:
	cd archlinuxarm-docker && \
		test -f ArchLinuxARM-aarch64-latest.tar.gz || curl -fLO http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz && \
		$(PODMAN) build --platform=linux/arm64 -t localhost/archlinuxarm:latest .

.PHONY: image
image:
	$(PODMAN) build \
		--platform=$(PLATFORM) \
		--security-opt=label=disable \
		--cap-add=all \
		--device /dev/fuse \
		--iidfile /tmp/image-id \
		$(if $(MEMORY),--memory=$(MEMORY)) \
		$(if $(MEMORY_SWAP),--memory-swap=$(MEMORY_SWAP)) \
		$(LABELS) \
		-t $(IMAGE_NAME) \
		-f $(VERSION_MAJOR)$(SUFFIX)/Containerfile \
		.

rechunk:
	$(PODMAN) run \
		--rm --privileged \
		--security-opt=label=disable \
		-v /var/lib/containers:/var/lib/containers:z \
		quay.io/centos-bootc/centos-bootc:stream10 \
		/usr/libexec/bootc-base-imagectl rechunk \
		localhost/$(IMAGE_NAME):latest localhost/rechunked-$(IMAGE_NAME):latest && \
	$(PODMAN) tag localhost/rechunked-$(IMAGE_NAME):latest localhost/$(IMAGE_NAME):latest && \
	$(PODMAN) rmi localhost/rechunked-$(IMAGE_NAME):latest
