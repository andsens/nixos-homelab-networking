{ ... }:
{
  lib,
  pkgs,
  config,
  ...
}:
let
  ccfg = config.homelab.cluster;
  cfg = config.homelab.cilium.bgp;
  enable = config.homelab.cilium.enable && cfg.enable;
in
{
  options.homelab.cilium.bgp = {
    enable = lib.mkEnableOption "the provisioning of Cilium BGP configurations";
    routerIP4 = lib.mkOption {
      description = "IPv4 of the router for BGP communication";
      type = lib.types.str;
    };
    routerIP6 = lib.mkOption {
      description = "IPv6 of the router for BGP communication";
      type = lib.types.str;
    };
    clusterASN = lib.mkOption {
      description = "BGP ASN of the cluster";
      type = lib.types.int;
      default = 65000;
    };
    routerASN = lib.mkOption {
      description = "BGP ASN of the router";
      type = lib.types.int;
      default = 64512;
    };
  };
  config = {
    networking.tempAddresses = lib.mkIf enable "disabled";
    networking.firewall.allowedTCPPorts = pkgs.lib.optional enable 179;
    services.k3s.manifests.cilium-bgpconfig.enable = enable;
    kubetree.resources.cilium-bgpconfig =
      (lib.optionalAttrs ccfg.enableIPv4 {
        peer4 = {
          apiVersion = "cilium.io/v2";
          kind = "CiliumBGPPeerConfig";
          metadata.name = "cilium-peer4";
          spec = {
            timers.holdTimeSeconds = 9;
            timers.keepAliveTimeSeconds = 3;
            gracefulRestart.enabled = true;
            gracefulRestart.restartTimeSeconds = 15;
            families = [
              {
                afi = "ipv4";
                safi = "unicast";
                advertisements.matchLabels.advertise = "bgp";
              }
            ];
          };
        };
      })
      // (lib.optionalAttrs ccfg.enableIPv6 {
        peer6 = {
          apiVersion = "cilium.io/v2";
          kind = "CiliumBGPPeerConfig";
          metadata.name = "cilium-peer6";
          spec = {
            timers.holdTimeSeconds = 9;
            timers.keepAliveTimeSeconds = 3;
            gracefulRestart.enabled = true;
            gracefulRestart.restartTimeSeconds = 15;
            families = [
              {
                afi = "ipv6";
                safi = "unicast";
                advertisements.matchLabels.advertise = "bgp";
              }
            ];
          };
        };
      })
      // {
        router = {
          apiVersion = "cilium.io/v2";
          kind = "CiliumBGPClusterConfig";
          metadata.name = "router";
          spec.bgpInstances = lib.optionals enable [
            {
              name = "router";
              localASN = cfg.clusterASN;
              peers =
                lib.optional ccfg.enableIPv4 {
                  name = "router4";
                  peerASN = cfg.routerASN;
                  peerAddress = cfg.routerIP4;
                  peerConfigRef.name = "cilium-peer4";
                }
                ++ lib.optional ccfg.enableIPv6 {
                  name = "router6";
                  peerASN = cfg.routerASN;
                  peerAddress = cfg.routerIP6;
                  peerConfigRef.name = "cilium-peer6";
                };
            }
          ];
        };
        advertisements = {
          apiVersion = "cilium.io/v2";
          kind = "CiliumBGPAdvertisement";
          metadata.name = "bgp-advertisements";
          metadata.labels.advertise = "bgp";
          spec.advertisements = [
            {
              advertisementType = "PodCIDR";
              attributes.communities.standard = [ "65000:99" ];
              attributes.localPreference = 99;
            }
            {
              advertisementType = "Service";
              service.addresses = [
                "ClusterIP"
                "ExternalIP"
                "LoadBalancerIP"
              ];
              selector.matchExpressions = [
                {
                  key = "somekey";
                  operator = "NotIn";
                  values = [ "never-used-value" ];
                }
              ];
            }
          ];
        };
      };
  };
}
