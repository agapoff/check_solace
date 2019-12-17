#!/usr/bin/env perl
##########################
# Perform checks against Solace Message Routers
# Designed for usage with Nagios, Icinga, Shinken... Whatever.
#
# Vitaly Agapov <v.agapov@quotix.com>
# 2017/02/27
# Last modified: 2019/12/16
##########################

use strict;
use warnings;
use Getopt::Long qw/GetOptions :config no_ignore_case/;
use Data::Dumper qw/Dumper/;
use File::Basename qw/basename dirname/;
use lib dirname(__FILE__);
use Solace::SEMP;
use XML::LibXML;

our $VERSION = '0.09';
our %CODE=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
our %ERROR=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

&help if ! @ARGV;
our %opt;
GetOptions(
    \%opt,
    'help|h',
    'warning|w=s',
    'critical|c=s',
    'rwarning|rw=s',
    'rcritical|rc=s',
    'version|V=s',
    'mode|m=s',
    'vpn|v=s',
    'name|n=s',
    'host|H=s',
    'port|p=s',
    'username|u=s',
    'password|P=s',
    'type|y=s',
    'checkadb|a',
    'checkhba|b',
    'debug|D',
    'tls|t',
);

&help if (! $opt{host} || ! $opt{mode} || ! $opt{version});

my $semp = Solace::SEMP->new( %opt );

my $exitStatus = $CODE{OK};

if ($opt{mode} eq 'redundancy') {
    my $req = $semp->getRedundancy;
    if (! $req->{error} ) {
        my $configStatus = $req->{result}->{'config-status'}->[0];
        my $redundancyStatus = $req->{result}->{'redundancy-status'}->[0];
        my $redundancyMode = $req->{result}->{'redundancy-mode'}->[0];
        my $mate = $req->{result}->{'mate-router-name'}->[0] || 'N/A';
        if ($configStatus ne 'Enabled' || $redundancyStatus ne 'Up') {
            $exitStatus = $CODE{CRITICAL};
        }
        print $ERROR{$exitStatus}.". Config: $configStatus, Status: $redundancyStatus, Mode: $redundancyMode, Mate: $mate\n";
        exit $exitStatus;
    } else {
        fail($req->{error});
    }
}
elsif ($opt{mode} eq 'hardware') {
    # Got the necessary monitoring information from an old Solace plugin
    # Only adjusted everything to work with this plugin
    my $req = $semp->getHardware;
    if (! $req->{error} ) {
        $opt{warning} ||= 2;
        my $dom = XML::LibXML->load_xml(string => $req->{raw});
        my @output;
        my @exitCodes;
        my $matelinkCount = 0;
        my $fiberChannelCount = 0;

        # Check Power Supplies always
        my $powerSupplies = $dom->findvalue("/rpc-reply/rpc/show/hardware/power-redundancy/operational-power-supplies");
        # Specify your warning threshold for this, default is 2
        if ($powerSupplies < $opt{warning}) {
            $exitStatus = $CODE{WARNING};
            push @exitCodes,$exitStatus;
        }
        my $powerOutput = sprintf("Power (Operational Supplies: %s)",$powerSupplies);
        push @output,$powerOutput;

        # Check the Assured Delivery Blade (ADB)
        if (defined $opt{checkadb}){
            # Check the Operational Status
            my $ADBOperational = $dom->findvalue("/rpc-reply/rpc/show/hardware/fabric/slot/card-type[text()='Assured Delivery Blade']/../operational-state-up");
            if($ADBOperational ne "true"){
                $exitStatus = $CODE{CRITICAL};
                push @exitCodes,$exitStatus;
            }
            # Check the Mate Link 1 state
            my $mateLink1 = $dom->findvalue("/rpc-reply/rpc/show/hardware/fabric/slot/card-type[text()='Assured Delivery Blade']/../mate-link-1-state");
            if($mateLink1 eq "Ok"){
	            $matelinkCount++;
            }
            # Check the Mate Link 2 state
            my $mateLink2 = $dom->findvalue("/rpc-reply/rpc/show/hardware/fabric/slot/card-type[text()='Assured Delivery Blade']/../mate-link-2-state");
            if($mateLink2 eq "Ok"){
	            $matelinkCount++;
            }
            $exitStatus=$CODE{CRITICAL}-$matelinkCount;
            push @exitCodes,$exitStatus;
            # Check the Power Module State
            my $powerModule = $dom->findvalue("/rpc-reply/rpc/show/hardware/fabric/slot/card-type[text()='Assured Delivery Blade']/../power-module-state");
            if($powerModule ne "Ok"){
	            $exitStatus = $CODE{CRITICAL};
                push @exitCodes,$exitStatus;
            }
            # Check for any Fatal Errors
            my $fatalErrors = $dom->findvalue("/rpc-reply/rpc/show/hardware/fabric/slot/card-type[text()='Assured Delivery Blade']/../fatal-errors");
            if($fatalErrors > 0){
	            $exitStatus = $CODE{CRITICAL};
                push @exitCodes,$exitStatus;
            }
            # Check the Flash state
            my $flashState = $dom->findvalue("/rpc-reply/rpc/show/hardware/fabric/slot/card-type[text()='Assured Delivery Blade']/../flash/state");
            if($flashState ne "Ready"){
	            $exitStatus = $CODE{CRITICAL};
                push @exitCodes,$exitStatus;
            }
            my $outputADB = sprintf("ADB (Operational State: %s, Power Module State: %s, Mate Link Port 1: %s, Mate Link Port 2: %s, Fatal Errors: %s, Flash Card State: %s)",$ADBOperational,$powerModule,$mateLink1,$mateLink2,$fatalErrors,$flashState);
            push @output,$outputADB;
        }

        # Check Host Bus Adapter (HBA)
        if(defined $opt{checkhba}){
            # Check Fiber Channel port 1
            my $fiberChannel1 = $dom->findvalue("/rpc-reply/rpc/show/hardware/fabric/slot/fibre-channel/number[text()='1']/../operational-state");
            if($fiberChannel1 eq "Online"){
                $fiberChannelCount++;
            }

            # Check Fiber Channel port 2
            my $fiberChannel2 = $dom->findvalue("/rpc-reply/rpc/show/hardware/fabric/slot/fibre-channel/number[text()='2']/../operational-state");
            if($fiberChannel2 eq "Online"){
                $fiberChannelCount++;
            }
            $exitStatus=$CODE{CRITICAL}-$fiberChannelCount;
            push @exitCodes,$exitStatus;

            # Check External Disk (LUN)	
            my $lun = $dom->findvalue("/rpc-reply/rpc/show/hardware/fabric/slot/external-disk-lun/state");

            # Lun give different outputs after solace firmware upgrade. 
            # Just quick hack to fix monitoring until all appliances is upgraded.
            if($lun ne 'Ready' && $lun ne 'ReadyReady' && $lun ne 'ReadyReadyReady') {
                $exitStatus = $CODE{CRITICAL};
                push @exitCodes,$exitStatus;
            }
            my $outputHBA = sprintf("HBA (Fiber Channel 1: %s, Fiber Channel 2: %s, LUN: %s)",$fiberChannel1,$fiberChannel2,$lun);
            push @output,$outputHBA;
        }
        # Juggle exitcodes ordered by criticality
        @exitCodes = reverse sort { $a <=> $b } @exitCodes; 
        $exitStatus = $exitCodes[0];
        print $ERROR{$exitStatus}.": ".join(" ",@output)."\n";
        exit $exitStatus;    
    } else {
        fail($req->{error});
    }
}
elsif ($opt{mode} eq 'config-sync') {
    my $req = $semp->getConfigSync;
    if (! $req->{error} ) {
        my $adminStatus = $req->{result}->{'admin-status'}->[0];
        my $operStatus = $req->{result}->{'oper-status'}->[0];
        if ($operStatus ne 'Up') {
            $exitStatus = $CODE{CRITICAL};
        }
        print $ERROR{$exitStatus}.". Oper status: $operStatus, Admin status: $adminStatus\n";
        exit $exitStatus;
    } else {
        fail($req->{error});
    }
}
elsif ($opt{mode} eq 'alarm') {
    my $req = $semp->getAlarm;
    if ($req) {
        print $req."\n";
        exit $CODE{CRITICAL};
    } else {
        print "OK. No alarms\n";
        exit $CODE{OK}
    }
}
elsif ($opt{mode} eq 'raid') {
    if ($opt{version} =~ /VMR/) {
        fail("Mode not supported by VMR");
    }
    my $req = $semp->getRaid;
    if (! $req->{error} ) {
        my $raidState = $req->{result}->{'raid-state'}->[0];
        if (! defined $raidState) {
            print "No RAID found (may be VMR)\n";
            exit $CODE{CRITICAL};
        }
        if ($raidState ne 'in fully redundant state') {
            $exitStatus = $CODE{CRITICAL};
        }
        print $ERROR{$exitStatus}.". RAID $raidState. ";
        my $count = -1;
        foreach (@{$req->{result}->{'administrative-state-enabled'}}) {
            $count++;
            if ($_ eq 'true') {
                print "Disk ".$req->{result}->{number}->[$count]." State: ".$req->{result}->{state}->[$count].". ";
            }
        }
        print "\n";
        exit $exitStatus;
    } else {
        fail($req->{error});
    }
}
elsif ($opt{mode} eq 'disk') {
    $opt{warning} ||= 80;
    $opt{critical} ||= 95;
    if ($opt{version} =~ /VMR/) {
        my $req = $semp->getStorageElement;
        #print Dumper($req);
        if (! $req->{error} ) {
            my $count = -1;
            my $output = '';
            my @perfdata;
            foreach my $name (@{$req->{result}->{name}}) {
                $count++;
                my $usage = $req->{result}->{'used-percentage'}->[$count];
                $usage =~ s/\..*//;
                if ($usage >= $opt{critical}) {
                    $exitStatus = $CODE{CRITICAL};
                } elsif ($usage >= $opt{warning} && $exitStatus < $CODE{CRITICAL}) {
                    $exitStatus = $CODE{WARNING};
                }
                $output .= $name." usage ".$usage."%. ";
                push @perfdata,"'$name'=$usage%;$opt{warning};$opt{critical}";
            }
            my $perfdataOut = join ' ',@perfdata;
            print $ERROR{$exitStatus}.". ".$output." | ".$perfdataOut."\n";
            exit $exitStatus;
        } else {
            fail($req->{error});
        }
    }
    else {
        my $req = $semp->getDiskUsage;
        if (! $req->{error} ) {
            my $count = -1;
            my $output = '';
            my @perfdata;
            foreach (@{$req->{result}->{type}}) {
                $count++;
                next if ($_ eq 'tmpfs' || $_ eq 'devtmpfs');
                my $usage = $req->{result}->{use}->[$count];
                my $mountPoint = $req->{result}->{'mounted-on'}->[$count];
                $usage =~ s/\%//;
                if ($usage >= $opt{critical}) {
                    $exitStatus = $CODE{CRITICAL};
                } elsif ($usage >= $opt{warning} && $exitStatus < $CODE{CRITICAL}) {
                    $exitStatus = $CODE{WARNING};
                }
                $output .= $mountPoint." usage ".$usage."%. ";
                push @perfdata,"'$mountPoint'=$usage%;$opt{warning};$opt{critical}";
            }
            if (! $output) {
                print "No disks found (may be VMR)\n";
                exit $CODE{CRITICAL};
            }

            my $perfdataOut = join ' ',@perfdata;
            print $ERROR{$exitStatus}.". ".$output." | ".$perfdataOut."\n";
            exit $exitStatus;
        } else {
            fail($req->{error});
        }
    }
}
elsif ($opt{mode} eq 'memory') {
    $opt{warning} ||= 50;
    $opt{critical} ||= 95;
    my $req = $semp->getMemoryUsage;
    if (! $req->{error} ) {
        my $physMemUsage = sprintf("%.2f",$req->{result}->{'physical-memory-usage-percent'}->[0]);
        my $subscrMemUsage = sprintf("%.2f",$req->{result}->{'subscription-memory-usage-percent'}->[0]);
        if ($physMemUsage >= $opt{critical} || $subscrMemUsage >= $opt{critical}) {
            $exitStatus = $CODE{CRITICAL};
        } elsif ( $physMemUsage >= $opt{warning} || $subscrMemUsage >= $opt{warning}) {
            $exitStatus = $CODE{WARNING};
        }
        print $ERROR{$exitStatus}.". Physical mem usage $physMemUsage%. Subscriptions mem usage $subscrMemUsage% | 'physical-memory-usage'=$physMemUsage%;$opt{warning};$opt{critical} 'subscription-memory-usage'=$subscrMemUsage%;$opt{warning};$opt{critical}\n";
        exit $exitStatus;
    } else {
        fail($req->{error});
    }
}
elsif ($opt{mode} eq 'environment') {
    my $req = $semp->getEnvironment;
    if (! $req->{error} ) {
        my $count = -1;
        my $output = '';
        foreach (@{$req->{result}->{status}}) {
            $count++;
            next if ($_ eq 'OK' || $_ eq '');
            $exitStatus = $CODE{CRITICAL};
            $output .= $req->{result}->{'type'}->[$count].' '.$req->{result}->{'name'}->[$count].' '.
            $req->{result}->{'value'}->[$count].' '.$req->{result}->{'unit'}->[$count].' '.
            $req->{result}->{'status'}->[$count].'. ';
        }
        print "Environment ".$ERROR{$exitStatus}.' '.$output."\n";
        exit $exitStatus;
    } else {
        fail($req->{error});
    }
}
elsif ($opt{mode} eq 'interface') {
    if (! $opt{name} ) {
        print "Interface name not defined\n";
        exit $CODE{CRITICAL};
    }
    my $req = $semp->getInterface(name => $opt{name});
    if (! $req->{error} ) {
        my $output = '';
        my $rxBytes = $req->{result}->{'rx-bytes'}->[0];
        my $txBytes = $req->{result}->{'tx-bytes'}->[0];
        my $rxPkts  = $req->{result}->{'rx-pkts'}->[0];
        my $txPkts  = $req->{result}->{'tx-pkts'}->[0];
        my $enabled = $req->{result}->{enabled}->[0];
        my $mode    = $req->{result}->{mode}->[0];
        my $link    = $req->{result}->{'link-detected'}->[0];
        if (! defined $enabled) {
            print "Interface $opt{name} not found\n";
            exit $CODE{CRITICAL};
        }
        $output .= "Iface $opt{name}, Enabled: $enabled, ";
        if ($mode) {
            my $members = $req->{result}->{'operational-members'};
            $output .= "Mode: $mode, Operational Members: $members";
            if (! $members > 0) { $exitStatus = $CODE{CRITICAL}; }
        } else {
            $output .= "Link: $link";
            if ($link ne 'yes') { $exitStatus = $CODE{CRITICAL}; }
        }
        $output .= " | 'rx-bytes'=$rxBytes 'tx-bytes'=$txBytes 'rx-pkts'=$rxPkts 'tx-pkts'=$txPkts";
        print $ERROR{$exitStatus}.' '.$output."\n";
        exit $exitStatus;
    } else {
        fail($req->{error});
    }
}
elsif ($opt{mode} eq 'clients') {
    $opt{warning} ||= 1000;
    $opt{critical} ||= 1000;

    my $req = $semp->getClientStats;
    if (! $req->{error} ) {
        my $clients = $req->{result}->{'total-clients-connected'}->[0];
        my $ingressRate = $req->{result}->{'average-ingress-rate-per-minute'}->[0];
        my $egressRate = $req->{result}->{'average-egress-rate-per-minute'}->[0];
        my $ingressByteRate = $req->{result}->{'average-ingress-byte-rate-per-minute'}->[0];
        my $egressByteRate = $req->{result}->{'average-egress-byte-rate-per-minute'}->[0];
        my $ingressDiscards = $req->{result}->{'total-ingress-discards'}->[0];
        my $egressDiscards = $req->{result}->{'total-egress-discards'}->[0];

        if ($clients >= $opt{critical}) {
            $exitStatus = $CODE{CRITICAL};
        } elsif ( $clients >= $opt{warning}) {
            $exitStatus = $CODE{WARNING};
        }
        print $ERROR{$exitStatus}.". $clients connected, Rate $ingressRate/$egressRate msg/sec, ".
        "Discarded $ingressDiscards/$egressDiscards | 'connected'=$clients;$opt{warning};$opt{critical} ".
        "'ingress-rate'=$ingressRate 'egress-rate'=$egressRate 'ingress-byte-rate'=$ingressByteRate ".
        "'egress-byte-rate'=$egressByteRate 'ingress-discards'=$ingressDiscards 'egress-discards'=$egressDiscards\n";
        exit $exitStatus;
    } else {
        fail($req->{error});
    }
}
elsif ($opt{mode} eq 'client') {
    if (! $opt{vpn} ) {
        print "Message-vpn not defined\n";
        exit $CODE{CRITICAL};
    }
    if (! $opt{name} ) {
        print "Client name not defined\n";
        exit $CODE{CRITICAL};
    }

    my $req = $semp->getVpnClientStats(name => $opt{name}, vpn => $opt{vpn});
    if (! $req->{error} ) {
        if (! defined $req->{result}->{'name'}) {
            fail("Client not connected");
        }
        my $count = scalar @{ $req->{result}->{'name'} };
        if ($count < 1) {
            fail("Client not connected");
        }
        my $name;
        if ($count > 1) {
            $name = "$count clients";
        } else {
            $name = $req->{result}->{'name'}->[0];
        }
        my $ingressRate = sum($req->{result}->{'average-ingress-rate-per-minute'});
        my $egressRate = sum($req->{result}->{'average-egress-rate-per-minute'});
        my $ingressByteRate = sum($req->{result}->{'average-ingress-byte-rate-per-minute'});
        my $egressByteRate = sum($req->{result}->{'average-egress-byte-rate-per-minute'});
        my $ingressDiscards = sum($req->{result}->{'total-ingress-discards'});
        my $egressDiscards = sum($req->{result}->{'total-egress-discards'});
        my $dataMessagesReceived = sum($req->{result}->{'client-data-messages-received'});
        my $dataMessagesSent = sum($req->{result}->{'client-data-messages-sent'});

        print $ERROR{$exitStatus}.". $name\@$opt{vpn} Rate $ingressRate/$egressRate msg/sec, ".
        "Discarded $ingressDiscards/$egressDiscards | ".
        "'ingress-rate'=$ingressRate 'egress-rate'=$egressRate 'ingress-byte-rate'=$ingressByteRate ".
        "'egress-byte-rate'=$egressByteRate 'ingress-discards'=$ingressDiscards 'egress-discards'=$egressDiscards ".
        "'data-messages-received'=$dataMessagesReceived 'data-messages-sent'=$dataMessagesSent\n";
        exit $exitStatus;
    } else {
        fail($req->{error});
    }
}
elsif ($opt{mode} eq 'vpn-clients') {
    if (! $opt{vpn} ) {
        $opt{vpn} = '*';
    }
    if (! $opt{name} ) {
        $opt{name} = '*';
    }

    my $req = $semp->getVpnClientDetail(name => $opt{name}, vpn => $opt{vpn});
    if (! $req->{error} ) {
        my $count = 0;
        my $public_count = 0;
        my $private_count = 0;
        my %platform_count;
        my $platform_perf = "";
        foreach (@{$req->{result}->{'client-address'}}) {
            $count++;
            if (! isPrivate($_) ) { $public_count++; }
            else { $private_count++; }
        }
        foreach (@{$req->{result}->{'description'}}) {
            $platform_count{getPlatformFromUA($_)}++;
        }
        foreach (sort keys %platform_count) {
            $platform_perf .= " 'ua-$_'=".$platform_count{$_};
        }

        if (defined $opt{critical} && $count <= $opt{critical}) {
            $exitStatus = $CODE{CRITICAL};
        } elsif (defined $opt{warning} && $count <= $opt{warning}) {
            $exitStatus = $CODE{WARNING};
        }

        $opt{warning} ||= '';
        $opt{critical} ||= '';
        print $ERROR{$exitStatus}.". $opt{name}\@$opt{vpn}: $count clients, $public_count from public IPs | ".
        "'clients'=$count;$opt{warning};$opt{critical} 'clients-public'=$public_count 'clients-private'=$private_count".
        $platform_perf."\n";
        exit $exitStatus;
    } else {
        fail($req->{error});
    }
}
elsif ($opt{mode} eq 'client-username') {
    $opt{warning}  ||= 80;
    $opt{critical} ||= 95;

    if (! $opt{vpn} ) {
        print "Message-vpn not defined\n";
        exit $CODE{CRITICAL};
    }
    if (! $opt{name} ) {
        print "Client-username (name) not defined\n";
        exit $CODE{CRITICAL};
    }

    my $req = $semp->getVpnClientUsernameStats(name => $opt{name}, vpn => $opt{vpn});
    #$print Dumper($req);
    if (! $req->{error} ) {
        my $c = -1;
        my %values;
        my @stats = ('message-vpn', 'num-clients', 'num-clients-service-web', 'num-clients-service-smf', 'num-endpoints',
            'max-connections', 'max-connections-service-web', 'max-connections-service-smf', 'max-endpoints');
        my $crit = '';
        my $output;
        my $perf;

        foreach my $clientUsername (@{$req->{result}->{'client-username'}}) {
            $c++;
            next if ($clientUsername =~ /^#/);
            foreach (@stats) {
                $values{$clientUsername}->{$_} = $req->{result}->{$_}->[$c];
            }
            my $vpn = $values{$clientUsername}->{'message-vpn'};

            my $maxConnections = $values{$clientUsername}->{'max-connections'};
            my $numClients = $values{$clientUsername}->{'num-clients'};
            my $connectionUsage = ($maxConnections > 0) ? $numClients * 100 / $maxConnections : 0;
            my $maxUsage = $connectionUsage;

            my $maxConnectionsWeb = $values{$clientUsername}->{'max-connections-service-web'};
            my $numClientsWeb = $values{$clientUsername}->{'num-clients-service-web'};
            my $webUsage = ($maxConnectionsWeb > 0) ? $numClientsWeb * 100 / $maxConnectionsWeb : 0;
            $maxUsage = $webUsage if ($webUsage > $maxUsage);

            my $maxConnectionsSmf = $values{$clientUsername}->{'max-connections-service-smf'};
            my $numClientsSmf = $values{$clientUsername}->{'num-clients-service-smf'};
            my $smfUsage = ($maxConnectionsSmf > 0) ? $numClientsSmf * 100 / $maxConnectionsSmf : 0;
            $maxUsage = $smfUsage if ($smfUsage > $maxUsage);

            $values{$clientUsername}->{'max-usage'} = $maxUsage;
            if ( $maxUsage >= $opt{critical} ) {
                $exitStatus = $CODE{CRITICAL};
                $crit .= " $clientUsername\@$vpn usage $maxUsage%;";
            }
            elsif ($maxUsage >= $opt{warning} && $exitStatus != $CODE{CRITICAL}) {
                $exitStatus = $CODE{WARNING};
                $crit .= " $clientUsername\@$vpn usage $maxUsage%;";
            }

            if ($c <= 4) {
                $output .= " $clientUsername\@$vpn clients $numClients/$maxConnections web $numClientsWeb/$maxConnectionsWeb".
                " smf $numClientsSmf/$maxConnectionsSmf;";
            }

            (my $perfUsername = $clientUsername) =~ s/\./\-/g;
            $perf .= " '$perfUsername-num-clients'=$numClients '$perfUsername-num-clients-web'=$numClientsWeb".
            " '$perfUsername-num-clients-smf'=$numClientsSmf";
        }

        $c++;
        if ($c > 5) {
            $output .= "...Total ".$c. " clients";
        }
        $perf .= " 'num-clients'=".$c;

        print $ERROR{$exitStatus} . '.' . $crit . $output . ' |' . $perf . "\n";
        exit $exitStatus;
    } else {
        fail($req->{error});
    }
}
elsif ($opt{mode} eq 'vpn') {
    $opt{warning} ||= 50;
    $opt{critical} ||= 95;
    $opt{rwarning} ||= 10000;
    $opt{rcritical} ||= 15000;

    $opt{vpn} ||= $opt{name};

    if (! $opt{vpn} ) {
        print "Message-vpn not defined\n";
        exit $CODE{CRITICAL};
    }

    my $req = $semp->getMessageVpnStats(name => $opt{vpn});
    if (! $req->{error} ) {
        my $output = '';
        my $perf;
        # Its easier to get enabled value in bulk using XPath
        # In the former way we get the last value from the last enabled key
        # <kerberos-auth>
        #      <enabled>false</enabled>
        my $dom = XML::LibXML->load_xml(string => $req->{raw});

        # /rpc-reply/rpc/show/message-vpn/vpn
        foreach my $vpn ($dom->findnodes('//vpn')) {
            my $name =  $vpn->findvalue('./name');
            my $enabled = $vpn->findvalue('./enabled');
            my $operational = $vpn->findvalue('./operational');
            my $status = $vpn->findvalue('./local-status');
 
            if ($enabled eq 'true' && $operational eq 'true' && $status eq 'Up') {
                my $uniqueSubscriptions =  $vpn->findvalue('./unique-subscriptions');
                my $maxSubscriptions =  $vpn->findvalue('./max-subscriptions');
                my $maxConnections =  $vpn->findvalue('./max-connections');
                my $connSMF =  $vpn->findvalue('./connections-service-smf');
                my $connWEB =  $vpn->findvalue('./connections-service-web');
                my $connMQTT =  $vpn->findvalue('./connections-service-mqtt');
                my $ingressByteRate =  $vpn->findvalue('./stats/average-ingress-byte-rate-per-minute');
                my $egressByteRate =  $vpn->findvalue('./stats/average-egress-byte-rate-per-minute');
                my $connections =  $vpn->findvalue('./connections');
                my $ingressRate =  $vpn->findvalue('./stats/average-ingress-rate-per-minute');
                my $egressRate =  $vpn->findvalue('./stats/average-egress-rate-per-minute');
                my $ingressDiscards =  $vpn->findvalue('./stats/ingress-discards/total-ingress-discards');
                my $egressDiscards =  $vpn->findvalue('./stats/egress-discards/total-egress-discards');

                # Metric to monitor recommended by Solace Co.
                my $spoolEgressDiscards =  $vpn->findvalue('./stats/egress-discards/msg-spool-egress-discards');
                my $connUsage = 0;
                if ($maxConnections > 0) {
                    $connUsage = sprintf("%.2f",$connections / $maxConnections);
                }
                my $subscrUsage = 0;
                if ($maxSubscriptions > 0) {
                    $subscrUsage = sprintf("%.2f",$uniqueSubscriptions / $maxSubscriptions);
                }
                # Only issues will be shown in Output giving preference to perfdata
                if ($connUsage >= $opt{critical} || $subscrUsage >= $opt{critical} || $ingressRate >= $opt{rcritical} || $egressRate >= $opt{rcritical}) {
                    $exitStatus = $CODE{CRITICAL};
                    $output .=  "$name-Subs $uniqueSubscriptions/$maxSubscriptions, $name-Conns $connections/$maxConnections ".
                    "$name-Ingress-Rate $ingressRate;$opt{rwarning};$opt{rcritical}, $name-Egress-Rate $egressRate;$opt{rwarning};$opt{rcritical} ";
                } elsif ($connUsage >= $opt{warning} || $subscrUsage >= $opt{warning} || $ingressRate >= $opt{rwarning} || $egressRate >= $opt{rwarning}) {
                    $exitStatus = $CODE{WARNING};
                    $output .=  "$name-Subs $uniqueSubscriptions/$maxSubscriptions, $name-Conns $connections/$maxConnections ".
                    "$name-Ingress-Rate $ingressRate;$opt{rwarning};$opt{rcritical}, $name-Egress-Rate $egressRate;$opt{rwarning};$opt{rcritical} ";
                }
                $perf .=    "'$name-unique-subscriptions'=$uniqueSubscriptions ".
                            "'$name-subscriptions-usage'=$subscrUsage%;$opt{warning};$opt{critical} '$name-connections'=$connections ".
                            "'$name-conn-usage'=$connUsage%;$opt{warning};$opt{critical} ".
                            "'$name-conn-smf'=$connSMF '$name-conn-web'=$connWEB '$name-conn-mqtt'=$connMQTT ".
                            "'$name-ingress-rate'=$ingressRate;$opt{rwarning};$opt{rcritical} '$name-egress-rate'=$egressRate;$opt{rwarning};$opt{rcritical} ".
                            "'$name-ingress-byte-rate'=$ingressByteRate '$name-egress-byte-rate'=$egressByteRate '$name-ingress-discards'=$ingressDiscards ".
                            "'$name-egress-discards'=$egressDiscards '$name-spool-egress-discards'=$spoolEgressDiscards ";
            } else {
                # VPN with issues
                $exitStatus = $CODE{CRITICAL};
                $output .= " $name Enabled: $enabled, Operational: $operational, Status: $status;";   
            }
        }
        print $ERROR{$exitStatus}." ".$output."|".$perf."\n";
        exit $exitStatus;
    } else {
        fail($req->{error});
    }
}
elsif ($opt{mode} eq 'spool') {
    $opt{warning} ||= 50;
    $opt{critical} ||= 95;

    $opt{vpn} ||= $opt{name};

    if (! $opt{vpn} ) {
        print "Message-vpn not defined\n";
        exit $CODE{CRITICAL};
    }

    my $req = $semp->getSpoolUsage(vpn => $opt{vpn});
    if (! $req->{error} ) {
        my $c = -1;
        my %values;
        my @stats = ('current-spool-usage-mb', 'current-messages-spooled', 'maximum-spool-usage-mb', 'maximum-queues-and-topic-endpoints', 'current-queues-and-topic-endpoints', 'maximum-egress-flows', 'current-egress-flows', 'maximum-ingress-flows', 'current-ingress-flows', 'maximum-transactions', 'current-transactions', 'maximum-transacted-sessions', 'current-transacted-sessions');
        my $crit = '';
        my $output;
        my $perf;
        if (! defined $req->{result}->{'name'}) {
            print "Message VPN $opt{vpn} not known\n";
            exit $CODE{CRITICAL};
        }
        foreach my $messageVPN (@{$req->{result}->{'name'}}) {
            $c++;
            last if (! defined $req->{result}->{'current-spool-usage-mb'}->[$c]);
            foreach (@stats) {
                $values{$messageVPN}->{$_} = $req->{result}->{$_}->[$c] if (defined $req->{result}->{$_}->[$c]);
            }

            my $currentMessagesSpooled = $values{$messageVPN}->{'current-messages-spooled'};
            my $currentSpoolUsage = $values{$messageVPN}->{'current-spool-usage-mb'};
            my $maxSpoolUsage = $values{$messageVPN}->{'maximum-spool-usage-mb'};
            my $percUsage = ($maxSpoolUsage > 0) ? $currentSpoolUsage * 100 /$maxSpoolUsage : 0;
            if ($percUsage >= $opt{critical}) {
                $exitStatus = $CODE{CRITICAL};
            } elsif ($percUsage >= $opt{warning} && $exitStatus != $CODE{CRITICAL}) {
                $exitStatus = $CODE{WARNING};
            }

            $output .= " $messageVPN spool usage ".sprintf("%.1f",$percUsage)."% ($currentSpoolUsage/$maxSpoolUsage MB)";
            (my $perfMessageVPN = $messageVPN) =~ s/\./\-/g;
            $perf .= " '$perfMessageVPN-spool-usage'=$percUsage;$opt{warning};$opt{critical} '$perfMessageVPN-spool-usage-mb'=$currentSpoolUsage '$perfMessageVPN-messages-spooled'=$currentMessagesSpooled '$perfMessageVPN-max-spool-usage-mb'=$maxSpoolUsage";

            # A set of additional params are included only if only one message-vpn is selected
            if (defined $values{$messageVPN}->{'current-queues-and-topic-endpoints'}) {
                my $currentEndpoints = $values{$messageVPN}->{'current-queues-and-topic-endpoints'};
                my $maxEndpoints = $values{$messageVPN}->{'maximum-queues-and-topic-endpoints'};
                my $currentEgressFlows = $values{$messageVPN}->{'current-egress-flows'};
                my $maxEgressFlows = $values{$messageVPN}->{'maximum-egress-flows'};
                my $currentIngressFlows = $values{$messageVPN}->{'current-ingress-flows'};
                my $maxIngressFlows = $values{$messageVPN}->{'maximum-ingress-flows'};
                my $currentTransactions = $values{$messageVPN}->{'current-transactions'};
                my $maxTransactions = $values{$messageVPN}->{'maximum-transactions'};
                my $currentTransactedSessions = $values{$messageVPN}->{'current-transacted-sessions'};
                my $maxTransactedSessions = $values{$messageVPN}->{'maximum-transacted-sessions'};

                my $endpointsUsage = ($maxEndpoints > 0) ? $currentEndpoints * 100 / $maxEndpoints : 0;
                my $egressFlowsUsage = ($maxEgressFlows > 0) ? $currentEgressFlows * 100 / $maxEgressFlows : 0;
                my $ingressFlowsUsage = ($maxIngressFlows > 0) ? $currentIngressFlows * 100 / $maxIngressFlows : 0;
                my $transactionsUsage = ($maxTransactions > 0) ? $currentTransactions * 100 / $maxTransactions : 0;
                my $transactedSessionsUsage = ($maxTransactedSessions > 0) ? $currentTransactedSessions * 0 / $maxTransactedSessions : 100;

                if ($endpointsUsage >= $opt{critical} || $egressFlowsUsage >= $opt{critical} || $ingressFlowsUsage >= $opt{critical} ||
                    $transactionsUsage >= $opt{critical} || $transactedSessionsUsage >= $opt{critical}) {
                    $exitStatus = $CODE{CRITICAL};
                } elsif ($endpointsUsage >= $opt{warning} || $egressFlowsUsage >= $opt{warning} || $ingressFlowsUsage >= $opt{warning} ||
                    $transactionsUsage >= $opt{warning} || $transactedSessionsUsage >= $opt{warning}) {
                    $exitStatus = $CODE{WARNING};
                }
                $output .= " endpoints usage ".sprintf("%.1f",$endpointsUsage)."% ($currentEndpoints/$maxEndpoints)".
                           " egress flows usage ".sprintf("%.1f",$egressFlowsUsage)."% ($currentEgressFlows/$maxEgressFlows)".
                           " ingress flows usage ".sprintf("%.1f",$ingressFlowsUsage)."% ($currentIngressFlows/$maxIngressFlows)".
                           " transactions usage ".sprintf("%.1f",$transactionsUsage)."% ($currentTransactions/$maxTransactions)".
                           " transacted sessions usage ".sprintf("%.1f",$transactedSessionsUsage)."% ($currentTransactedSessions/$maxTransactedSessions)";
                $perf    = "'spool-usage'=$percUsage;$opt{warning};$opt{critical} 'spool-usage-mb'=$currentSpoolUsage".
                           " 'messages-spooled'=$currentMessagesSpooled 'max-spool-usage-mb'=$maxSpoolUsage".
                           " 'endpoints'=$currentEndpoints 'max-endpoints'=$maxEndpoints".
                           " 'egress-flows'=$currentEgressFlows 'max-egress-flows'=$maxEgressFlows".
                           " 'ingress-flows'=$currentIngressFlows 'max-ingress-flows'=$maxIngressFlows".
                           " 'transactions'=$currentTransactions 'max-transactions'=$maxTransactions".
                           " 'transacted-sessions'=$currentTransactedSessions 'max-transacted-sessions'=$maxTransactedSessions";
            }
       }
       print $ERROR{$exitStatus}.".".$output."|".$perf."\n";
       exit $exitStatus;
    } else {
        fail($req->{error});
    }
}
elsif ($opt{mode} eq 'queue' || $opt{mode} eq 'topic-endpoint') {
    $opt{warning}  ||= 500;
    $opt{critical} ||= 1000;

    $opt{name} ||= '*';
    $opt{vpn}  ||= '*';

    my $req = $semp->getEndpoints(vpn => $opt{vpn}, name => $opt{name}, endpoint => $opt{mode}, type => $opt{type});
    if (! $req->{error} ) {
        my $c = -1;
        my $upEndpoints = 0; # counter for endpoints with admin status Up
        my %values;
        my @stats = ('ingress-config-status', 'egress-config-status', 'num-messages-spooled', 'current-spool-usage-in-mb', 'topic-subscription-count', 'bind-count', 'high-water-mark-in-mb');
        my $output = '';
        my $perf;
        if (! defined $req->{result}->{'name'}) {
            print "No endpoints $opt{name} in message VPN $opt{vpn}\n";
            exit $CODE{CRITICAL};
        }
        foreach my $name (@{$req->{result}->{'name'}}) {
            $c++;
            my $messageVPN = $req->{result}->{'message-vpn'}->[$c];
            my $id = $name.'@'.$messageVPN;
            foreach (@stats) {
                $values{$id}->{$_} = $req->{result}->{$_}->[$c];
            }

            # Only enabled endpoints taken into account
            next unless ($values{$id}->{'ingress-config-status'} eq 'Up' && $values{$id}->{'egress-config-status'} eq 'Up');
            $upEndpoints++;

            my $messagesSpooled = $values{$id}->{'num-messages-spooled'};
            my $messagesSpooledMB = $values{$id}->{'current-spool-usage-in-mb'};
            if ($messagesSpooled >= $opt{critical}) {
                $exitStatus = $CODE{CRITICAL};
                $output .= " $messagesSpooled messages spooled in $id;";
            } elsif ($messagesSpooled >= $opt{warning} && $exitStatus != $CODE{CRITICAL}) {
                $exitStatus = $CODE{WARNING};
                $output .= " $messagesSpooled messages spooled in $id;";
            }

            (my $perfId = $id) =~ s/\./\-/g;
            $perf .= " '$perfId-messages-spooled'=$messagesSpooled;$opt{warning};$opt{critical} '$perfId-spool-usage-in-mb'=$messagesSpooledMB";
       }
       if (! $upEndpoints) {
            print "No enabled endpoints $opt{name} in message VPN $opt{vpn}\n";
            exit $CODE{CRITICAL};
       }
       print $ERROR{$exitStatus}.". Total ".$upEndpoints." ".$opt{mode}."s.".$output."|".$perf."\n";
       exit $exitStatus;
    } else {
        fail($req->{error});
    }

}
else {
    fail("Invalid mode ".$opt{mode});
}

sub fail {
    my $text = shift;
    print $text."\n";
    exit $CODE{CRITICAL};
}

sub isPrivate {
    my $ip = shift;
    if ($ip =~ /(^127\.)|(^10\.)|(^172\.1[6-9]\.)|(^172\.2[0-9]\.)|(^172\.3[0-1]\.)|(^192\.168\.)/) { return 1; }
    return;
}

sub getPlatformFromUA {
    my $ua = shift;
    if ($ua =~ /iP(hone|od|ad)/) {
        return 'iphone';
    } elsif ($ua =~ /Android/) {
        return 'android';
    } elsif ($ua =~ /Linux/) {
        return 'linux';
    } elsif ($ua =~ /Macintosh/) {
        return 'mac';
    } elsif ($ua =~ /Windows/) {
        return 'windows';
    }
    return 'other';
}

# Sum for arrayref
sub sum {
   my $arr = shift;
   my $sum;
   $sum += $_ for @{$arr};
   return $sum;
}

sub help {
    my $me = basename($0);
    print qq{Usage: $me -H host -V version -m mode [ -p port ] [ -u username ]
                        [ -P password ] [ -v vpn ] [ -n name ] [ -t ] [ -D ]
                        [ -w warning ] [ -c critical ] [ -rw rwarning ] [ -rc rcritical ]
                        [ -y type ] [ -a ] [ -b ]

Run checks against Solace Message Router using SEMP protocol.
Returns with an exit code of 0 (success), 1 (warning), 2 (critical), or 3 (unknown)
This is version $VERSION.

Common connection options:
 -H,  --host=NAME       hostname to connect to
 -p,  --port=NUM        port to connect to; defaults to 80.
 -u,  --username=NAME   management user to connect as; defaults to 'admin'
 -P,  --password=PASS   management user password; defaults to 'admin'
 -V,  --version=NUM     Solace version (i.e. 8.0, 8.3VMR etc.)
 -m,  --mode=STRING     test to perform
 -v,  --vpn=STRING      name of the message-vpn
 -n,  --name=STRING     name of the interface, queue, endpoint, client or message-vpn to test (needed when the corresponding mode is selected)
 -y,  --type=STRING     type parameter for durable or non-durable queues and topic endpoints, if not specified it will get both
 -a,  --checkadb        choose this option to monitor Hardware ADB (works with the hardware mode)
 -b,  --checkhba        choose this option to monitor Hardware HBA (works with the hardware mode)
 -t,  --tls             SEMP service is encrypted with TLS
 -D,  --debug           debug mode

Limit options:
  -w value, --warning=value   the warning threshold, range depends on the action
  -c value, --critical=value  the critical threshold, range depends on the action
  -rw value, --rwarning=value   the warning threshold, specific for rates when another value is already present
  -rc value, --rcritical=value  the critical threshold, specific for rates when another value is already present

Modes:
  redundancy
  config-sync
  alarm (deprecated after 7.2)
  raid
  disk
  hardware
  memory
  interface
  clients
  client
  client-username
  vpn-clients
  vpn
  spool
  queue
  topic-endpoint
};
  exit 0;
}
