{ inputs, self, ... }:
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.homelab.privacyVPN;
in
{
  options.homelab.privacyVPN = {
    enable = lib.mkEnableOption "the privacy VPN";
    clientIP4 = lib.mkOption {
      description = "Internal tunnel IPv4 of the client";
      type = lib.types.nullOr lib.types.str;
    };
    clientIP6 = lib.mkOption {
      description = "Internal tunnel IPv6 of the client";
      type = lib.types.nullOr lib.types.str;
    };
    gatewayAddress = lib.mkOption {
      description = "Address for wireguard to connect to";
      type = lib.types.str;
    };
    gatewayPublicKey = lib.mkOption {
      description = "Public key of the VPN gateway";
      type = lib.types.str;
    };
    gatewayIP4 = lib.mkOption {
      description = "Internal tunnel IPv4 of the VPN gateway";
      type = lib.types.nullOr lib.types.str;
    };
    gatewayIP6 = lib.mkOption {
      description = "Internal tunnel IPv6 of the VPN gateway";
      type = lib.types.nullOr lib.types.str;
    };
  };
  imports = [ inputs.setup-secrets.nixosModules.default ];
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.homelab.cilium.masquerade.enable;
        message = "In order to use the privacy VPN, masquerading must be enabled (homelab.cluster.masquerade.enable)";
      }
    ];
    kubetree.resources = {
      vpn-egress.privacy-vpn = {
        apiVersion = "cilium.io/v2";
        kind = "CiliumEgressGatewayPolicy";
        metadata.name = "privacy-vpn";
        spec = {
          egressGateway = {
            nodeSelector.matchLabels."node-role.kubernetes.io/control-plane" = "true";
            interface = "privacy-vpn";
          };
          selectors = [ { podSelector.matchLabels."cluster.local/egress-gateway" = "privacy-vpn"; } ];
          destinationCIDRs =
            lib.optional (cfg.clientIP4 != null) "0.0.0.0/0" ++ lib.optional (cfg.clientIP6 != null) "::/0";
        };
      };
    };
    networking.wireguard.interfaces.privacy-vpn = {
      ips =
        lib.optional (cfg.clientIP4 != null) "${cfg.clientIP4}/32"
        ++ lib.optional (cfg.clientIP6 != null) "${cfg.clientIP6}/128";
      table = "4242";
      peers = [
        {
          name = "Privacy VPN Gateway";
          endpoint = cfg.gatewayAddress;
          publicKey = cfg.gatewayPublicKey;
          allowedIPs =
            lib.optional (cfg.clientIP4 != null) "0.0.0.0/0" ++ lib.optional (cfg.clientIP6 != null) "::/0";
        }
      ];
      privateKeyFile = "/etc/secrets.d/privacy-vpn.key";
    };
    setup-secrets = {
      sources.PRIVACY_VPN_PRIVATE_KEY = {
        description = "Private Key for privacy VPN connection";
        cmd = self.lib.setup-secrets.mkScript pkgs ''cat "${config.networking.wireguard.interfaces.privacy-vpn.privateKeyFile}"'';
      };
      destinations = [
        {
          logPrefix = "Privacy VPN Private Key File";
          requires = [ "PRIVACY_VPN_PRIVATE_KEY" ];
          cmd = self.lib.setup-secrets.mkScript pkgs ''
            umask 077
            printf "%s" "$PRIVACY_VPN_PRIVATE_KEY" >"${config.networking.wireguard.interfaces.privacy-vpn.privateKeyFile}"
          '';
        }
      ];
    };
    networking.useNetworkd = true; # very much needed for this setup to work in the way it's configured
    systemd.network.networks."40-privacy-vpn" = {
      routingPolicyRules =
        lib.optional (cfg.gatewayIP4 != null) {
          To = "${cfg.gatewayIP4}/32";
          Table = config.networking.wireguard.interfaces.privacy-vpn.table;
        }
        ++ lib.optional (cfg.gatewayIP6 != null) {
          To = "${cfg.gatewayIP6}/128";
          Table = config.networking.wireguard.interfaces.privacy-vpn.table;
        }
        ++ lib.optional (cfg.clientIP4 != null) {
          From = "${cfg.clientIP4}/32";
          Table = config.networking.wireguard.interfaces.privacy-vpn.table;
        }
        ++ lib.optional (cfg.clientIP6 != null) {
          From = "${cfg.clientIP6}/128";
          Table = config.networking.wireguard.interfaces.privacy-vpn.table;
        };
    };
  };
}
