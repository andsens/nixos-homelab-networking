{ ... }:
{
  config,
  lib,
  ...
}:
let
  ccfg = config.homelab.cluster;
  cfg = config.homelab.cilium.cidr-groups;
  enable = config.homelab.cilium.enable && cfg.enable;
in
{
  options.homelab.cilium.cidr-groups = {
    enable = lib.mkEnableOption "Cilium";
    localLANCIDR4 = lib.mkOption {
      description = "IPv4 CIDR of the local LAN";
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    localLANCIDR6 = lib.mkOption {
      description = "IPv6 CIDR of the local LAN";
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
  };
  config = {
    services.k3s.manifests.cidrgroups.enable = enable;
    kubetree.resources.cidrgroups = {
      pods = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumCIDRGroup";
        metadata.name = "pods";
        spec.externalCIDRs =
          (lib.optional ccfg.enableIPv4 ccfg.podCidr4) ++ (lib.optional ccfg.enableIPv6 ccfg.podCidr6);
      };
      services = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumCIDRGroup";
        metadata.name = "services";
        spec.externalCIDRs =
          (lib.optional ccfg.enableIPv4 ccfg.svcCidr4) ++ (lib.optional ccfg.enableIPv6 ccfg.svcCidr6);
      };
      local-lan = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumCIDRGroup";
        metadata.name = "local-lan";
        spec.externalCIDRs =
          lib.optional (cfg.localLANCIDR4 != null) cfg.localLANCIDR4
          ++ lib.optional (cfg.localLANCIDR6 != null) cfg.localLANCIDR6;
      };
    };
  };
}
