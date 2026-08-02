{ inputs, self, ... }:
{
  pkgs,
  lib,
  config,
  ...
}:
let
  ccfg = config.homelab.cluster;
  cfg = config.homelab.routedIPPool;
in
{
  key = "${toString __curPos.file}#modules.nixos.routed-ippool";
  options.homelab.routedIPPool = {
    enable = lib.mkEnableOption "the loadbalancer IP pool that is routed to the cluster from the network";
    debug = lib.mkEnableOption "debug mode";
    lbIpBlock4.cidr = lib.mkOption {
      description = "IPv4 CIDR";
      type = lib.types.nullOr lib.types.str;
      default = "10.45.0.0/16";
    };
    lbIpBlock4.start = lib.mkOption {
      description = "IPv4 Pool range start";
      type = lib.types.str;
      default = "10.45.0.2";
    };
    lbIpBlock4.stop = lib.mkOption {
      description = "IPv4 Pool range end";
      type = lib.types.str;
      default = "10.45.0.254";
    };
    lbIpBlock6.cidr = lib.mkOption {
      description = "IPv6 CIDR";
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    lbIpBlock6.start = lib.mkOption {
      description = "IPv6 Pool range start";
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    lbIpBlock6.stop = lib.mkOption {
      description = "IPv6 Pool range end";
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
  };
  config = lib.mkIf cfg.enable {
    kubetree.resources.routed-lbippool = {
      cilium-lbippool = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumLoadBalancerIPPool";
        metadata.name = "routed";
        spec.blocks =
          (lib.optional ccfg.enableIPv4 (
            if cfg.lbIpBlock4.start != null then
              { inherit (cfg.lbIpBlock4) start stop; }
            else
              { inherit (cfg.lbIpBlock4) cidr; }
          ))
          ++ (lib.optional ccfg.enableIPv6 (
            if cfg.lbIpBlock6.start != null then
              { inherit (cfg.lbIpBlock6) start stop; }
            else
              { inherit (cfg.lbIpBlock6) cidr; }
          ));
        spec.serviceSelector.matchLabels."cluster.local/ippool" = "routed";
      };
    };
  };
}
