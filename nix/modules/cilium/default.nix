{ inputs, self, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  ccfg = config.homelab.cluster;
  cfg = config.homelab.cilium;
  kubelib = inputs.kube-generators.lib { inherit pkgs; };
  charts = inputs.nixhelm.charts { inherit pkgs; };
in
{
  key = "${toString __curPos.file}#modules.nixos.cilium";
  options.homelab.cilium = {
    enable = lib.mkEnableOption "cilium";
    lbIpBlock4.cidr = lib.mkOption {
      description = "IPv4 CIDR for the load balancers";
      type = lib.types.nullOr lib.types.str;
      default = "10.44.0.0/16";
    };
    lbIpBlock4.start = lib.mkOption {
      description = "IP Pool range start for the load balancers";
      type = lib.types.str;
      default = "10.44.0.2";
    };
    lbIpBlock4.stop = lib.mkOption {
      description = "IP Pool range end for the load balancers";
      type = lib.types.str;
      default = "10.44.0.254";
    };
    lbIpBlock6.cidr = lib.mkOption {
      description = "IPv6 CIDR for the load balancers";
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    lbIpBlock6.start = lib.mkOption {
      description = "IPv6 Pool range start for the load balancers";
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    lbIpBlock6.stop = lib.mkOption {
      description = "IPv6 Pool range end for the load balancers";
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    masquerade.enable = lib.mkOption {
      description = "Whether to turn on masquerading (automatically turned on if \${config.homelab.privacyVPN.enable} is on)";
      type = lib.types.bool;
      default = config.homelab.privacyVPN.enable;
    };
    extraConfig = lib.mkOption {
      description = "Additional Cilium helm configuration values to apply";
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
  };
  imports = self.lib.importsApply [
    ./bgp.nix
    ./cidr-groups.nix
    ./firewall.nix
    ./network-policies.nix
  ];
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.homelab.privacyVPN.enable || cfg.masquerade.enable;
        message = "In order to use the privacy VPN, masquerading must be enabled (homelab.cluster.masquerade.enable)";
      }
    ];
    services.k3s.disable = [
      "traefik"
      "servicelb"
    ];
    services.k3s.manifests = {
      gatewayapi.source = pkgs.fetchurl {
        url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/experimental-install.yaml";
        hash = "sha256-ZOx2YJpqyIXgQF3qecpQnCKfoBnTQvCFeqi2vci4upI=";
      };
      cilium-helm.source = kubelib.buildHelmChart {
        name = "cilium";
        namespace = "cilium";
        chart = charts.cilium.cilium;
        values = lib.recursiveUpdate (
          {
            hostFirewall.enabled = cfg.firewall.enable;

            ipam.mode = "kubernetes";

            routingMode = "native";
            autoDirectNodeRoutes = true;

            kubeProxyReplacement = true;

            bgpControlPlane.enabled = cfg.bgp.enable;
            nodeIPAM.enabled = true; # TODO: Needed?

            egressGateway.enabled = config.homelab.privacyVPN.enable;

            tls.secretsNamespace.name = "cilium";
            operator.replicas = 1;
            kubeConfigPath = "/etc/rancher/k3s/k3s.yaml";
            k8sServiceHost = "127.0.0.1";
            k8sServicePort = "6443";

            envoy.enabled = false;
            hubble.enabled = false;
            hubble.relay.gops.enabled = false;

            gatewayAPI.enabled = true;
            gatewayAPI.enableAlpn = true;
            gatewayAPI.enableAppProtocol = true;
            gatewayAPI.gatewayClass.create = "true";

            ipv4.enabled = ccfg.enableIPv4;
            ipv6.enabled = ccfg.enableIPv6;
            k8s.requireIPv4PodCIDR = ccfg.enableIPv4;
            k8s.requireIPv6PodCIDR = ccfg.enableIPv6;

            bpf.masquerade = cfg.masquerade.enable;
          }
          // lib.optionalAttrs ccfg.enableIPv4 {
            ipv4NativeRoutingCIDR = ccfg.podCidr4;
            enableIPv4Masquerade = cfg.masquerade.enable;
          }
          // lib.optionalAttrs ccfg.enableIPv6 {
            ipv6NativeRoutingCIDR = ccfg.podCidr6;
            enableIPv6Masquerade = cfg.masquerade.enable;
          }
        ) cfg.extraConfig;
      };
    };

    kubetree.resources.cilium-lbippool.pool = {
      apiVersion = "cilium.io/v2";
      kind = "CiliumLoadBalancerIPPool";
      metadata.name = "main";
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
    };
  };
}
