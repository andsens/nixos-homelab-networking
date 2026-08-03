{ ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.cilium.firewall;
  enable = config.homelab.cilium.enable && cfg.enable;
in
{
  options.homelab.cilium.firewall = {
    enable = lib.mkEnableOption "the Cilium host firewall (disables the NixOS firewall)";
  };
  config = {
    networking.firewall = lib.mkIf enable {
      enable = false;
      allowedUDPPorts = [ 68 ]; # DHCP, seems cilium host firewall blocks this
    };
    services.k3s.manifests.cilium-hostfirewall-policy.enable = enable;
    kubetree.resources.cilium-hostfirewall-policy.policy = {
      apiVersion = "cilium.io/v2";
      kind = "CiliumClusterwideNetworkPolicy";
      metadata = {
        name = "host-firewall";
      };
      spec.nodeSelector.matchLabels = { };
      spec.ingress = [
        { fromEntities = [ "cluster" ]; }
        {
          toPortsFlattened =
            (map (port: {
              port = builtins.toString port;
              protocol = "TCP";
            }) config.networking.firewall.allowedTCPPorts)
            ++ (map (port: {
              port = builtins.toString port;
              protocol = "UDP";
            }) config.networking.firewall.allowedUDPPorts)
            ++ (map (
              { from, to }:
              {
                port = builtins.toString from;
                endPort = to;
                protocol = "TCP";
              }
            ) config.networking.firewall.allowedTCPPortRanges)
            ++ (map (
              { from, to }:
              {
                port = builtins.toString from;
                endPort = to;
                protocol = "UDP";
              }
            ) config.networking.firewall.allowedUDPPortRanges);
        }
        {
          icmps = [
            { fields = lib.optional config.networking.firewall.allowPing { type = "EchoRequest"; }; }
          ];
        }
      ];
    };

  };
}
