# Talos image builds.
#
#   Pi 4B / CM5  -> stock Image Factory schematics
#   Pi 5         -> local build, because it carries one commit that is not upstream:
#                   cb393a0d7 "don't regenerate k8s certs on NTP spike status changes".
#                   The macb kernel work and the Pi 5 DTB/SATA msi-parent fix are both
#                   upstream as of v1.14.0-rc.2, so there is no custom kernel or overlay
#                   any more -- just imager + installer-base from the talos branch.
#
# Requires GNU Make 4+ (`gmake` on macOS) and the docker CLI with buildx, not podman's alias.

SHELL          := /bin/bash
FACTORY_HOST   := factory.talos.dev
TALOS_VERSION  ?= v1.14.0-rc.2

# Local build inputs for the Pi 5.
TALOS_SRC      ?= $(HOME)/Code/siderolabs/talos
TALOS_BRANCH   ?= fix/no-cert-regen-on-ntp-spike-rc2
REGISTRY       ?= 192.168.1.18:5005
# v0.2.1 is the first release containing 3efdf1a, which bumps raspberrypi_kernel_version to
# stable_20260724 and so rebuilds pcie-32bit-dma-pi5.dtbo with msi-parent = <&pciex1>.
# That is the SATA HAT fix; v0.2.0 and earlier drop the MSI doorbell and every command
# times out. Upstream is equivalent to the old local dtb-20260724-min overlay -- same patch
# set (0007 dropped, 0008 rebased, 0011-0014 absent) -- but that has not been A/B tested on
# hardware yet. If SATA misbehaves, fall back to 192.168.1.18:5005/sbc-raspberrypi:dtb-20260724-min.
OVERLAY_IMAGE  ?= ghcr.io/siderolabs/sbc-raspberrypi:v0.2.1

# System extensions. The worker schematics name these and let Image Factory resolve the
# version; a local imager build has to pin them by tag.
ISCSI_TOOLS_IMAGE      ?= ghcr.io/siderolabs/iscsi-tools:v0.2.0
UTIL_LINUX_TOOLS_IMAGE ?= ghcr.io/siderolabs/util-linux-tools:v1.6.8
DOCKER         := /opt/homebrew/bin/docker

# TAG comes from `git describe`, so a dirty tree yields "-dirty" and is not reproducible.
TALOS_TAG       = $(shell git -C $(TALOS_SRC) describe --tag --always --dirty --match 'v[0-9]*')
INSTALLER_TAG  ?= $(TALOS_TAG)

WORKER_SCHEMATICS := rpi4b cm5

.PHONY: all schematics images rpi5b-installer rpi5b-image check-clean clean help

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
	@case '$(TALOS_TAG)' in *-dirty) \
		echo "!! TAG is $(TALOS_TAG) -- refusing to build something unreproducible"; exit 1 ;; esac
	@echo ">> talos @ $(TALOS_TAG)"

# installer-base + imager from the talos branch. INSTALLER_ARCH=targetarch is required:
# the default 'all' pulls pkg-kernel-amd64, which is not being built.
.imager-$(TALOS_TAG): check-clean
	BUILDX_BUILDER=local $(MAKE) -C $(TALOS_SRC) installer-base imager \
		PLATFORM=linux/arm64 INSTALLER_ARCH=targetarch \
		PUSH=true REGISTRY_AND_USERNAME=$(REGISTRY)/talos
	@touch $@

profiles/%.yaml: profiles/%.yaml.tmpl
	@TALOS_TAG=$(TALOS_TAG) REGISTRY=$(REGISTRY) OVERLAY_IMAGE=$(OVERLAY_IMAGE) \
	 ISCSI_TOOLS_IMAGE=$(ISCSI_TOOLS_IMAGE) UTIL_LINUX_TOOLS_IMAGE=$(UTIL_LINUX_TOOLS_IMAGE) \
		envsubst '$$TALOS_TAG $$REGISTRY $$OVERLAY_IMAGE $$ISCSI_TOOLS_IMAGE $$UTIL_LINUX_TOOLS_IMAGE' < $< > $@

# Installer image, for machine.install.image and `talosctl upgrade`.
rpi5b-installer: .imager-$(TALOS_TAG) profiles/rpi5b-installer.yaml
	@mkdir -p _out
	podman run -i --rm --tls-verify=false -v $(PWD)/_out:/out \
		$(REGISTRY)/talos/imager:$(TALOS_TAG) - < profiles/rpi5b-installer.yaml
	crane push --insecure _out/installer-arm64.tar $(REGISTRY)/talos/installer:$(INSTALLER_TAG)
	@echo ">> installer: $(REGISTRY)/talos/installer:$(INSTALLER_TAG)"

# Bootable SD image, for the initial flash only.
rpi5b-image: .imager-$(TALOS_TAG) profiles/rpi5b-metal.yaml
	@mkdir -p images
	podman run -i --rm --tls-verify=false -v $(PWD)/images:/out \
		$(REGISTRY)/talos/imager:$(TALOS_TAG) - < profiles/rpi5b-metal.yaml
	@mv images/metal-arm64.raw.xz images/talos-rpi5b.raw.xz
	@echo ">> image: images/talos-rpi5b.raw.xz"

clean:
	rm -f .schematic-id-* .imager-* profiles/*.yaml
	rm -rf images/ _out/

help:
	@echo "schematics       upload worker schematics to $(FACTORY_HOST)"
	@echo "images           download worker metal images"
	@echo "rpi5b-installer  build + push the Pi 5 installer (machine.install.image)"
	@echo "rpi5b-image      build the Pi 5 bootable SD image"
	@echo "clean            remove generated profiles, ids and images"
