# https://discourse.nixos.org/t/unifi-os-server-on-nixos/76039
{
  lib,
  stdenvNoCC,
  fetchurl,
  binwalk,
  coreutils,
  findutils,
  gnugrep,
  version,
  url,
  sha256,
}:
stdenvNoCC.mkDerivation {
  # reverse engineered via
  # https://www.unihosted.com/blog/running-unifi-os-server-in-docker
  name = "unifi-os-server-${version}.tar.gz";
  inherit version;

  src = fetchurl {
    inherit url sha256;
  };

  nativeBuildInputs = [
    binwalk
    coreutils
    findutils
    gnugrep
  ];

  dontUnpack = true;

  installPhase = ''
    set -euo pipefail
    binwalk -e $src >/dev/null
    image_tar="$(find . -type f -name image.tar | head -n1)"
    if [ -z "$image_tar" ]; then
      echo "Could not find embedded image.tar in UniFi OS installer" >&2
      exit 1
    fi
    gzip -c "$image_tar" > "$out"
  '';

  meta = with lib; {
    description = "Extracted OCI image archive from the UniFi OS Server installer";
    homepage = "https://help.ui.com/hc/en-us/articles/34210126298775-Self-Hosting-UniFi";
    license = licenses.unfreeRedistributableFirmware;
    platforms = platforms.linux;
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
  };
}
