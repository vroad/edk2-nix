let
  sources = import ./nix/sources.nix;
  pkgs = import sources.nixpkgs { };
  pkgs-gcc5 = import sources.nixpkgs-gcc5 { };
  srcs = with pkgs; {
    edk2 = (fetchFromGitHub {
      owner = "tianocore";
      repo = "edk2";
      rev = "b33cf5bfcb4c941370739dfbbe1532ff508fd29d";
      sha256 = "06h4cl4q79v65n10bvpindvxygh42y6z1p1g54z0b4vsq506ig54";
      fetchSubmodules = true;
    });
    ssdt-asl = ./ssdt.asl;
    vbios-rom = ./vbios.rom;
  };
in
with pkgs;
stdenv.mkDerivation
{
  name = "patched-ovmf";

  nativeBuildInputs = [
    python39
    iasl
    dos2unix
    pkgs-gcc5.pkgs.gcc5
    nasm
    unixtools.xxd
    libuuid
  ];

  phases = [ "unpackPhase" "patchPhase" "buildPhase" "installPhase" ];

  unpackPhase = ''
    cp -r ${srcs.edk2} edk2
    chmod -R u+rwX,go+rX,go-w edk2
    cp ${srcs.ssdt-asl} ssdt.asl
    ln -s ${srcs.vbios-rom} vbios.rom
    cd edk2
    dos2unix OvmfPkg/AcpiPlatformDxe/QemuFwCfgAcpi.c \
      BaseTools/Conf/tools_def.template \
      BaseTools/Source/C/Makefiles/header.makefile \
      CryptoPkg/Library/OpensslLib/OpensslLibCrypto.inf
  '';
  sourceRoot = ".";
  patchPhase = ''
    cd "$NIX_BUILD_TOP/edk2"
    patch -p1 < ${./disable-tests.patch}
    patch -p1 < ${./disable-gcc-warnings.patch}
    patch -p1 < ${./nvidia-hack.diff}
    cd "$NIX_BUILD_TOP/edk2/CryptoPkg/Library/OpensslLib/openssl"
    patchShebangs --build "$NIX_BUILD_TOP/edk2/BaseTools/BinWrappers/PosixLike/"
  '';

  buildPhase = ''
    BIOS_ROM="$NIX_BUILD_TOP/vbios.rom"
    cd "$NIX_BUILD_TOP/edk2/OvmfPkg/AcpiPlatformDxe"

    # Modify vrom.h, and rename the unsigned char array to VROM_BIN
    # and modify the length variable at the end to VROM_BIN_LEN
    xxd -i "$BIOS_ROM" | sed -e 's/unsigned char _build_vbios_rom\[\]/unsigned char VROM_BIN\[\]/' -e 's/unsigned int _build_vbios_rom_len =/unsigned int VROM_BIN_LEN =/' > vrom.h
    BIOS_ROM_REAL_PATH=`readlink -f "$BIOS_ROM"`
    BIOS_ROM_SIZE=`stat --printf="%s" "$BIOS_ROM_REAL_PATH"`
    # Modify ssdt.asl, change line 37 to match VROM_BIN_LEN
    sed -e "s/(RVBS, 102912)/(RVBS, $BIOS_ROM_SIZE)/" "$NIX_BUILD_TOP/ssdt.asl" > ssdt.asl
    # Run the following commands. Errors may pop up, but they're fine as long as Ssdt.aml is generated
    iasl -f ssdt.asl
    xxd -c1 Ssdt.aml | tail -n +37 | cut -f2 -d' ' | paste -sd' ' | sed 's/ //g' | xxd -r -p > vrom_table.aml
    xxd -i vrom_table.aml | sed 's/vrom_table_aml/vrom_table/g' > vrom_table.h
    # Switch back to edk2's folder
    cd "$NIX_BUILD_TOP/edk2"
    make -C BaseTools
    . ./edksetup.sh BaseTools
    mv ./Conf/target.txt  ./Conf/target_old.txt
    # Modify variables in Conf/target.txt:
    sed -e 's#^ACTIVE_PLATFORM *= EmulatorPkg/EmulatorPkg.dsc#ACTIVE_PLATFORM = OvmfPkg/OvmfPkgX64.dsc#' \
      -e 's#^TARGET_ARCH *= IA32#TARGET_ARCH = X64#' \
      -e 's#^TOOL_CHAIN_TAG *= VS2015x86#TOOL_CHAIN_TAG = GCC5#' \
      -e 's#^TARGET *= DEBUG#TARGET = RELEASE#' \
      ./Conf/target_old.txt > ./Conf/target.txt
    # Compile
    build
  '';

  installPhase = ''
    mkdir "$out"
    cp -r "$NIX_BUILD_TOP/edk2/Build/OvmfX64/RELEASE_GCC5/FV/." "$out/"
  '';
}
