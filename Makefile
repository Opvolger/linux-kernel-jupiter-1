# Milk-V Jupiter (SpacemiT K1) + AMD GPU: check out, patch and build the kernel.
#
#   make help                     overview
#   make deb-7.3-modules          Debian package, modular kernel (initramfs)
#   make deb-7.3-builtin          Debian package, everything built in (no initramfs)
#
# For each version V (see VERSIONS) the patches live in linux-V-patches/; the kernel goes
# into linux-V/ (git worktree of .kernel.git) and is built out of tree in
# build/V-<flavor>/obj, so both configs can exist side by side.

VERSIONS ?= $(patsubst linux-%-patches,%,$(wildcard linux-*-patches))
FLAVORS  := builtin modules debian

defconfig_builtin := k1_amdgpu_defconfig
defconfig_modules := k1_amdgpu_modules_defconfig
defconfig_debian  := k1_amdgpu_debian_defconfig

ARCH          := riscv
CROSS_COMPILE ?= riscv64-linux-gnu-
JOBS          ?= $(shell nproc)
DIST          ?= trixie
# Empty = automatic: highest existing revision in DEBDIR + 1
PKGREV        ?=
DEBDIR        ?= $(CURDIR)
FIRMWARE_URL  ?= https://gitlab.com/kernel-firmware/linux-firmware.git
# Debian packages not to build: linux-headers can't be cross-built (no riscv64 glibc on
# the host), the -dbg package is ~1 GB of debug info (the debian flavor has DEBUG_INFO).
# Drop pkg.linux-upstream.nokerneldbg to get the -dbg package.
DEB_PROFILES  ?= pkg.linux-upstream.nokernelheaders pkg.linux-upstream.nokerneldbg

# LOCALVERSION= (empty): version comes from CONFIG_LOCALVERSION, without '+' or '-dirty'
KMAKE = $$(MAKE) --no-print-directory -C linux-$(1) O=$(CURDIR)/build/$(1)-$(2)/obj \
	ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) LOCALVERSION=

.DEFAULT_GOAL := help
.PHONY: help all firmware $(addprefix checkout-,$(VERSIONS))

help:
	@echo "Versions: $(VERSIONS)    flavors: $(FLAVORS)"
	@echo "  builtin = $(defconfig_builtin): everything built in, GPU firmware inside the kernel"
	@echo "  modules = $(defconfig_modules): modules + initramfs, firmware from /lib/firmware"
	@echo "  debian  = $(defconfig_debian): like modules, but with everything the Debian kernel enables"
	@echo
	@echo "  make checkout-V             create linux-V/ and apply missing patches"
	@echo "  make deb-V-FLAVOR           .config + linux-image-*.deb (into $(DEBDIR))"
	@echo "  make image-V-FLAVOR         only Image.gz, dtbs (and modules), no deb; for builtin also"
	@echo "                              Image-<release>.gz + k1-milkv-jupiter-<release>.dtb (into $(DEBDIR))"
	@echo "  make deb-V                  all flavors of version V"
	@echo "  make all                    all versions, all flavors"
	@echo "  make menuconfig-V-FLAVOR    change the config (then savedefconfig-V-FLAVOR)"
	@echo "  make savedefconfig-V-FLAVOR write the defconfig back to linux-V/arch/riscv/configs/"
	@echo "  make export-V               write the commits in linux-V/ back to linux-V-patches/"
	@echo "  make debian-defconfig-V     regenerate $(defconfig_debian) from configs/debian/"
	@echo "  make clean-V-FLAVOR         remove build/V-FLAVOR"
	@echo "  make firmware               clone linux-firmware/ (needed by the builtin flavor)"
	@echo
	@echo "Variables: PKGREV=<n> (package revision, automatic by default), JOBS=$(JOBS),"
	@echo "           DIST=$(DIST), CROSS_COMPILE=$(CROSS_COMPILE), DEBDIR=$(DEBDIR)"
	@echo "           DEB_PROFILES=\"$(DEB_PROFILES)\""

# Only the builtin flavor needs it: CONFIG_EXTRA_FIRMWARE_DIR="../linux-firmware"
# (relative to linux-V/)
firmware: linux-firmware

linux-firmware:
	git clone --depth 1 $(FIRMWARE_URL) $@

$(addprefix checkout-,$(VERSIONS)): checkout-%:
	scripts/kernel-tree.sh $*

all: $(addprefix deb-,$(VERSIONS))

# --- rules per version (V) and flavor (F) -----------------------------------------
define flavor_rules
.PHONY: deb-$(1)-$(2) image-$(1)-$(2) menuconfig-$(1)-$(2) savedefconfig-$(1)-$(2) \
	config-$(1)-$(2) clean-$(1)-$(2)

config-$(1)-$(2): checkout-$(1)
	$(call KMAKE,$(1),$(2)) $(defconfig_$(2))

deb-$(1)-$(2): config-$(1)-$(2) $(if $(filter builtin,$(2)),firmware)
	@rel=$$$$($(call KMAKE,$(1),$(2)) -s kernelrelease); \
	ver=$$$$($(call KMAKE,$(1),$(2)) -s kernelversion); \
	rev=$(PKGREV); \
	if [ -z "$$$$rev" ]; then \
		last=$$$$(ls $(DEBDIR) | sed -n "s/^linux-image-$$$${rel}_$$$${ver}-\([0-9]*\)_riscv64\.deb$$$$/\1/p" | sort -n | tail -1); \
		rev=$$$$(( $$$${last:-0} + 1 )); \
	fi; \
	echo ">> $$$$rel, package version $$$$ver-$$$$rev"; \
	rm -f build/$(1)-$(2)/*.deb; \
	DEB_BUILD_PROFILES="$(DEB_PROFILES)" \
	$(call KMAKE,$(1),$(2)) -j$(JOBS) KDEB_PKGVERSION=$$$$ver-$$$$rev \
		KDEB_CHANGELOG_DIST=$(DIST) DPKG_FLAGS=-d bindeb-pkg && \
	cp -v build/$(1)-$(2)/*.deb $(DEBDIR)/

image-$(1)-$(2): config-$(1)-$(2) $(if $(filter builtin,$(2)),firmware)
	$(call KMAKE,$(1),$(2)) -j$(JOBS) Image.gz dtbs $(if $(filter builtin,$(2)),,modules)
ifeq ($(2),builtin)
	@# Ready-to-use files (no modules, no initramfs needed), named after the release
	@rel=$$$$($(call KMAKE,$(1),$(2)) -s kernelrelease); o=build/$(1)-$(2)/obj; \
	cp -v $$$$o/arch/riscv/boot/Image.gz $(DEBDIR)/Image-$$$$rel.gz && \
	cp -v $$$$o/arch/riscv/boot/dts/spacemit/k1-milkv-jupiter.dtb \
		$(DEBDIR)/k1-milkv-jupiter-$$$$rel.dtb && \
	cp -v $$$$o/.config $(DEBDIR)/config-$$$$rel
endif

menuconfig-$(1)-$(2): checkout-$(1)
	@[ -f build/$(1)-$(2)/obj/.config ] || $(call KMAKE,$(1),$(2)) $(defconfig_$(2))
	$(call KMAKE,$(1),$(2)) menuconfig

savedefconfig-$(1)-$(2):
	$(call KMAKE,$(1),$(2)) savedefconfig
	@echo "Note: the comment block at the top of the defconfig is lost; add it back."
	cp build/$(1)-$(2)/obj/defconfig linux-$(1)/arch/riscv/configs/$(defconfig_$(2))

clean-$(1)-$(2):
	rm -rf build/$(1)-$(2)
endef

define version_rules
.PHONY: deb-$(1) export-$(1) debian-defconfig-$(1)
deb-$(1): $(foreach f,$(FLAVORS),deb-$(1)-$(f))
export-$(1):
	scripts/export-patches.sh $(1)
debian-defconfig-$(1): checkout-$(1)
	scripts/debian-defconfig.sh $(1)
$(foreach f,$(FLAVORS),$(eval $(call flavor_rules,$(1),$(f))))
endef

$(foreach v,$(VERSIONS),$(eval $(call version_rules,$(v))))
