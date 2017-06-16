# CHECK_SOLACE

Nagios-style checks against Solace Message Routers using SEMPv1 protocol. Designed for usage with Nagios, Icinga, Shinken... Whatever.

## Dependencies

 * Perl
 * LWP::UserAgent
 * perl-LWP-Protocol-https (if https is used)
 * MIME::Base64

## Script usage

    Usage: check_solace.pl -H host -V version -m mode [ -p port ] [ -u username ] [ -P password ]
       [ -n name ] [ -v vpn ] [ -t ] [ -D ] [ -w warning ] [ -c critical ] 
    Returns with an exit code of 0 (success), 1 (warning), 2 (critical), or 3 (unknown)
    This is version 0.02.
    
    Common connection options:
     -H,  --host=NAME       hostname to connect to
     -p,  --port=NUM        port to connect to; defaults to 80.
     -u,  --username=NAME   management user to connect as; defaults to 'admin' 
     -P,  --password=PASS   management user password; defaults to 'admin'
     -V,  --version=NUM     Solace version (i.e. 8.0)
     -m,  --mode=STRING     test to perform
     -v,  --vpn=STRING      name of the message-vpn
     -n,  --name=STRING     name of the interface or message-vpn to test (when the corresponding mode is selected)
     -t,  --tls             SEMP service is encrypted with TLS
     -D,  --debug           debug mode
    
    Limit options:
      -w value, --warning=value   the warning threshold, range depends on the action
      -c value, --critical=value  the critical threshold, range depends on the action

    Modes:
      redundancy
      alarm
      raid
      disk
      memory
      interface
      clients
      client
      vpn-clients
      client-username
      vpn

## Examples:

Check the interface. The output will differ depending on interface type (physical / link aggregation):

    ./check_solace.pl -H <...> --port=8080 --password=<...> --version=7.2 --mode=interface --name=intf0
    OK Iface intf0, Enabled: yes, Link: yes | 'rx-bytes'=56031686088 'tx-bytes'=22076095590 'rx-pkts'=285007113 'tx-pkts'=195647732

    ./check_solace.pl -H <...> --password=<...> --version=7.2 --mode=interface --name=chassis/lag1
    OK Iface chassis/lag1, Enabled: yes, Mode: Active-Backup, Operational Members: 1 | 'rx-bytes'=63969434 'tx-bytes'=303404299 'rx-pkts'=641129 'tx-pkts'=644760

Check message VPN quota usage and statistics:

    ./check_solace.pl -H <...> --port=8080 --password=<...> --version=7.2 --mode=vpn --name=<my_vpn> --warning=50 --critical=95
    OK. Subscriptions 16/500000, Connections 10/1000 | 'unique-subscriptions'=16 'subscriptions-usage'=0.00%;50;95 'connections'=10 'conn-usage'=0.01%;50;95 'conn-smf'=10 'conn-web'=0 'conn-mqtt'=0 'ingress-rate'=123 'egress-rate'=0 'ingress-byte-rate'=24439 'egress-byte-rate'=0 'ingress-discards'=51500040 'egress-discards'=19

Check memory usage:

    ./check_solace.pl -H <...> --port=8080 --password=<...> --version=7.2 --mode=memory
    WARNING. Physical mem usage 66.69%. Subscriptions mem usage 0.02% | 'physical-memory-usage'=66.69%;50;95 'subscription-memory-usage'=0.02%;50;95

Check redundancy (applicable for hardware appliances, not VMRs):

    ./check_solace.pl -H <...> --password=<...> --version=7.2 --mode=redundancy
    OK. Config: Enabled, Status: Up, Mode: Active/Active, Mate: sol02

Check if client is connected and get some stats:

    ./check_solace.pl -H <...> --password=<...> --version=7.2 --mode=client --name=my.client.* --vpn=my-vpn
    OK. my.client.1@my-vpn Rate 10/0 msg/sec, Discarded 37423/0 | 'ingress-rate'=10 'egress-rate'=0 'ingress-byte-rate'=0 'egress-byte-rate'=0 'ingress-discards'=37423 'egress-discards'=0

Check if amount of client connections is not exceeded:
    ./check_solace.pl -H <...> --password=<...> --version=7.2 --mode=client-username --name=* --vpn=my-vpn
    CRITICAL. default@my-vpn usage 100%; my-client@my-vpn clients 6/10 web 0/0 smf 6/10; default@my-vpn clients 19/100000 web 19/19 smf 0/0; | 'my-client-num-clients'=6 'my-client-num-clients-web'=0 'my-client-num-clients-smf'=6 'default-num-clients'=19 'default-num-clients-web'=19 'default-num-clients-smf'=0

Check if amount of Websocket clients is not less than needed:
    ./check_solace.pl -H <...> --password=<...> --version=7.2 --mode=vpn-clients --vpn=my-* --name=Gecko* --warning=100
    OK. Gecko*@my-*: 180 clients, 50 from public IPs | 'clients'=180;100; 'clients-public'=130 'clients-private'=50

## Example configuration for Icinga

Command:

    object CheckCommand "check-solace" {
      import "plugin-check-command"
      command = [ PluginDir + "/check_solace.pl" ]
      arguments = {
                "-H" = "$host.address$"
                "-p" = "$solace_port$"
                "-V" = "$solace_version$"
                "-u" = "$solace_user$"
                "-P" = "$solace_pass$"
                "-w" = "$warning$"
                "-c" = "$critical$"
                "-m" = "$solace_action$"
                "-n" = "$name$"
                "-v" = "$vpn$"
                "-t" = {
                        set_if = "$is_tls$"
                }
      }
    }

Services:

    apply Service "alarm" {
      import "generic-service"
      check_command = "check-solace"
      vars.solace_action = "alarm"
      assign where host.vars.solace_version
    }
 
    apply Service "memory" {
      import "generic-service"
      check_command = "check-solace"
      vars.solace_action = "memory"
      vars.warning = host.vars.mem_usage_warn
      vars.critical = host.vars.mem_usage_crit
      assign where host.vars.solace_version
    }
 
    apply Service "clients" {
      import "generic-service"
      check_command = "check-solace"
      vars.solace_action = "clients"
      vars.warning = host.vars.clients_warn
      vars.critical = host.vars.clients_crit
      assign where host.vars.solace_version
    }
 
    apply Service "redundancy" {
      import "generic-service"
      check_command = "check-solace"
      vars.solace_action = "redundancy"
      assign where host.vars.solace_version && ! host.vars.vmr
    }
    
    apply Service "raid" {
      import "generic-service"
      check_command = "check-solace"
      vars.solace_action = "raid"
      assign where host.vars.solace_version && ! host.vars.vmr
    }

    apply Service "disk" {
      import "generic-service"
      check_command = "check-solace"
      vars.solace_action = "disk"
      vars.warning = host.vars.disk_usage_warn
      vars.critical = host.vars.disk_usage_crit
      assign where host.vars.solace_version && ! host.vars.vmr
    }
 
    apply Service "Interface " for (iface => config in host.vars.ifaces) {
      import "generic-service"
      check_command = "check-solace"
      vars.solace_action = "interface"
      vars.name = iface
      assign where host.vars.solace_version
    }
 
    apply Service "VPN " for (vpn => config in host.vars.vpns) {
      import "generic-service"
      check_command = "check-solace"
      vars.solace_action = "vpn"
      vars.name = vpn
      vars.warning = host.vars.vpn_quota_warn
      vars.critical = host.vars.vpn_quota_crit
      assign where host.vars.solace_version
    }

    apply Service "Client " for (client => config in host.vars.clients) {
      import "generic-service"
      check_command = "check-solace"
      vars.solace_action = "client"
      vars += config
      assign where host.vars.solace_version
    }

    apply Service "Solace Usernames " for (client => config in host.vars.solace_client_usernames) {
      import "generic-service"
      check_command = "check-solace"
      vars.solace_action = "client-username"
      vars += config
      assign where host.vars.solace_version
    }



Host template:

    template Host "solace-host" {
      import "generic-host"
      vars.solace_user = "admin"
      vars.solace_pass = "admin"
      vars.solace_port = "80"
      vars.solace_version = "7.2"
      vars.disk_usage_warn = 80
      vars.disk_usage_crit = 95
      vars.mem_usage_warn = 50
      vars.mem_usage_crit = 95
      vars.clients_warn = 1000
      vars.clients_crit = 1000
      vars.vpn_quota_warn = 50
      vars.vpn_quota_crit = 95
    }

Hosts:

    object Host "solace-vmr01" {
      import "solace-host"
      address = "..."
      vars.solace_port = 8080
      vars.vmr = true
      vars.ifaces = {
        "intf0" = { ifname = "intf0" }
      }
      vars.vpns = {
        "vpn1" = { vpn = "vpn1" },
        "vpn2" = { vpn = "vpn2" }
      }
      vars.mem_usage_warn = 90
      vars.mem_usage_crit = 90
    }
    object Host "solace01" {
      import "solace-host"
      address = "..."
      vars.solace_pass = "..."
      vars.ifaces = {
        "1/6/lag1"     = { ifname = "1/6/lag1" }
        "chassis/lag1" = { ifname = "chassis/lag1" }
      }
      vars.vpns = {
        "vpn1" = { vpn = "vpn1" },
        "vpn2" = { vpn = "vpn2" },
      }
      vars.clients = {
        "client1" = { vpn = "vpn1",
                      name = "client.*" }
      }
      vars.solace_client_usernames = {
        "some description" = { vpn = "vpn1",
			                   name = "*" }
      }
    }

## Licence: GNU GPL v3
