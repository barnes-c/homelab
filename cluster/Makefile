# Talos image builds. Pi 4B / CM5 use Image Factory schematics; the Pi 5 needs a local
# build for its fan kernel (PKG_KERNEL below). See barnes-c/homelab-issues#15.
#
# Requires GNU Make 4+ (`gmake` on macOS) and the docker CLI with buildx, not podman's alias.

SHELL          := /bin/bash
FACTORY_HOST   := factory.talos.dev
TALOS_VERSION  ?= v1.15.0-beta.0

# Local build inputs for the Pi 5. TALOS_SRC must be checked out at TALOS_BRANCH.
TALOS_SRC      ?= $(HOME)/Code/siderolabs/talos
TALOS_BRANCH   ?= v1.15.0-beta.0
# Public packages: Talos pulls the installer anonymously. Pushing needs `docker login`,
# `podman login` and `crane auth login` against ghcr.io.
REGISTRY       ?= ghcr.io/barnes-c
# The overlay version is tied to the Talos release: v0.3.0's DTBs carry an RP1 PCIe topology
# patch that needs the 7.x kernel and kills end0 on 6.18. Use what
# factory.talos.dev/version/$(TALOS_VERSION)/overlays/official resolves for rpi_5.
OVERLAY_IMAGE  ?= ghcr.io/siderolabs/sbc-raspberrypi:v0.3.0@sha256:6f4e52953e8f7742672f39075610810f5767bfc15347930205a0a7f62175b58e

# System extensions. The worker schematics name these and let Image Factory resolve the
# version; a local imager build has to pin them by digest, because extension tags are
# re-pushed for newer Talos releases and a newer build fails to load on this one. These
# match what factory.talos.dev/version/$(TALOS_VERSION)/extensions/official resolves.
ISCSI_TOOLS_IMAGE      ?= ghcr.io/siderolabs/iscsi-tools:v0.2.0@sha256:5c887effab3457700938b66b4de1ebd89f1c5025f20fd3a07b095d2994eec0fa
UTIL_LINUX_TOOLS_IMAGE ?= ghcr.io/siderolabs/util-linux-tools:2.42.4@sha256:f7fac0baf758b7f1c19c779c95ac47e9a0c89b69e93b1849cfccdb7fb01e54ba

# Kernel with the RP1 PWM driver, without which the Pi 5 fan never spins. Built from
# ~/Code/siderolabs/pkgs branch feat/pwm-rp1-fan-v1.15.0-beta.0, see barnes-c/homelab-issues#8.
PKG_KERNEL     ?= $(REGISTRY)/talos/kernel:v1.15.0-alpha.0-75-g17fdd33-pwmrp1v12
KERNEL_SUFFIX  ?= -pwmfan
DOCKER         := /opt/homebrew/bin/docker

# TAG comes from `git describe`, so a dirty tree yields "-dirty" and is not reproducible.
# KERNEL_SUFFIX marks images built with PKG_KERNEL; the Talos version string itself is unchanged.
TALOS_TAG       = $(shell git -C $(TALOS_SRC) describe --tag --always --dirty --match 'v[0-9]*')$(KERNEL_SUFFIX)
INSTALLER_TAG  ?= $(TALOS_TAG)

WORKER_SCHEMATICS := rpi4b cm5

.PHONY: all schematics images pi5-installer pi5-image check-clean clean help

all: schematics images

# -- Worker schematics (Image Factory) ---------------------------------------

schematics: $(addprefix .schematic-id-,$(WORKER_SCHEMATICS))

.schematic-id-%: schematics/%.yaml
	@echo ">> uploading $* schematic"
	@curl -sfX POST https://$(FACTORY_HOST)/schematics \
		-H "Content-Type: application/yaml" \
		--data-binary @$< | jq -r .id > $@
	@echo "   $* schematic: $$(cat $@)"

images: $(addprefix images/talos-,$(addsuffix .raw.xz,$(WORKER_SCHEMATICS)))

images/talos-%.raw.xz: .schematic-id-%
	@mkdir -p images
	@echo ">> downloading $* image ($(TALOS_VERSION))"
	curl -fL "https://$(FACTORY_HOST)/image/$$(cat $<)/$(TALOS_VERSION)/metal-arm64.raw.xz" -o $@

# -- Pi 5 local build --------------------------------------------------------

# Guards TAG, so it has to match `git describe --dirty` semantics: tracked changes only.
# Untracked files (build output like _out_*) do not make describe report -dirty.
check-clean:
	@test -z "$$(git -C $(TALOS_SRC) status --porcelain --untracked-files=no)" || \
		{ echo "!! $(TALOS_SRC) has uncommitted tracked changes -- TAG would be '-dirty'"; \
		  git -C $(TALOS_SRC) status --short --untracked-files=no; exit 1; }
	@case '$(TALOS_TAG)' in *-dirty*) \
		echo "!! TAG is $(TALOS_TAG) -- refusing to build something unreproducible"; exit 1 ;; esac
	@echo ">> talos @ $(TALOS_TAG)"

# installer-base + imager from the talos branch. INSTALLER_ARCH=targetarch is required:
# the default 'all' pulls pkg-kernel-amd64, which is not being built.
.imager-$(TALOS_TAG): check-clean
	BUILDX_BUILDER=local $(MAKE) -C $(TALOS_SRC) installer-base imager \
		PLATFORM=linux/arm64 INSTALLER_ARCH=targetarch \
		PUSH=true REGISTRY_AND_USERNAME=$(REGISTRY)/talos PKG_KERNEL=$(PKG_KERNEL) \
		IMAGE_TAG_OUT=$(TALOS_TAG)
	@touch $@

profiles/%.yaml: profiles/%.yaml.tmpl
	@TALOS_TAG=$(TALOS_TAG) REGISTRY=$(REGISTRY) OVERLAY_IMAGE=$(OVERLAY_IMAGE) \
	 ISCSI_TOOLS_IMAGE=$(ISCSI_TOOLS_IMAGE) UTIL_LINUX_TOOLS_IMAGE=$(UTIL_LINUX_TOOLS_IMAGE) \
		envsubst '$$TALOS_TAG $$REGISTRY $$OVERLAY_IMAGE $$ISCSI_TOOLS_IMAGE $$UTIL_LINUX_TOOLS_IMAGE' < $< > $@

# Installer image, for machine.install.image and `talosctl upgrade`.
pi5-installer: .imager-$(TALOS_TAG) profiles/pi5-installer.yaml
	@mkdir -p _out
	podman run -i --rm -v $(CURDIR)/_out:/out \
		$(REGISTRY)/talos/imager:$(TALOS_TAG) - < profiles/pi5-installer.yaml
	crane push _out/installer-arm64.tar $(REGISTRY)/talos/installer:$(INSTALLER_TAG)
	@echo ">> installer: $(REGISTRY)/talos/installer:$(INSTALLER_TAG)"

# Bootable SD image, for the initial flash only.
pi5-image: .imager-$(TALOS_TAG) profiles/pi5-metal.yaml
	@mkdir -p images
	podman run -i --rm -v $(CURDIR)/images:/out \
		$(REGISTRY)/talos/imager:$(TALOS_TAG) - < profiles/pi5-metal.yaml
	@mv images/metal-arm64.raw.xz images/talos-pi5.raw.xz
	@echo ">> image: images/talos-pi5.raw.xz"

clean:
	rm -f .schematic-id-* .imager-* profiles/*.yaml
	rm -rf images/ _out/

help:
	@echo "schematics       upload worker schematics to $(FACTORY_HOST)"
	@echo "images           download worker metal images"
	@echo "pi5-installer  build + push the Pi 5 installer (machine.install.image)"
	@echo "pi5-image      build the Pi 5 bootable SD image"
	@echo "clean            remove generated profiles, ids and images"
