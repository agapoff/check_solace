#!/usr/bin/env perl
##########################
# Perform checks against Solace Message Routers
# Designed for usage with Nagios, Icinga, Shinken... Whatever.
#
# Vitaly Agapov <v.agapov@quotix.com>
# 2017/02/27
# Last modified: 2018/08/13
##########################

use strict;
use warnings;
use Getopt::Long qw/GetOptions :config no_ignore_case/;
use Data::Dumper qw/Dumper/;
use File::Basename qw/basename dirname/;
use lib dirname(__FILE__);
use Solace::SEMP;

our $VERSION = '0.08';
our %CODE=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
our %ERROR=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

&help if ! @ARGV;
our %opt;
GetOptions(
    \%opt,
    'help|h',
    'warning|w=s',
    'critical|c=s',
    'version|V=s',
    'mode|m=s',
    'vpn|v=s',
    'name|n=s',
    'host|H=s',
    'port|p=s',
    'username|u=s',
    'password|P=s',
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
        my $name = $req->{result}->{'name'}->[0];
        my $vpn = $req->{result}->{'message-vpn'}->[0];
        my $ingressRate = $req->{result}->{'average-ingress-rate-per-minute'}->[0];
        my $egressRate = $req->{result}->{'average-egress-rate-per-minute'}->[0];
        my $ingressByteRate = $req->{result}->{'average-ingress-byte-rate-per-minute'}->[0];
        my $egressByteRate = $req->{result}->{'average-egress-byte-rate-per-minute'}->[0];
        my $ingressDiscards = $req->{result}->{'total-ingress-discards'}->[0];
        my $egressDiscards = $req->{result}->{'total-egress-discards'}->[0];
        my $dataMessagesReceived = $req->{result}->{'client-data-messages-received'}->[0];
        my $dataMessagesSent = $req->{result}->{'client-data-messages-sent'}->[0];

        if (! defined($name) ) {
            fail("Client not connected");
        }

        print $ERROR{$exitStatus}.". $name\@$vpn Rate $ingressRate/$egressRate msg/sec, ".
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
        # print "Message-vpn not defined. Set --vpn=* to use all vpns\n";
        # exit $CODE{CRITICAL};
        $opt{vpn} = '*';
    }
    if (! $opt{name} ) {
        # print "Client name not defined. Set --name=* to count all clients\n";
        # exit $CODE{CRITICAL};
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

            $output .= " $clientUsername\@$vpn clients $numClients/$maxConnections web $numClientsWeb/$maxConnectionsWeb".
            " smf $numClientsSmf/$maxConnectionsSmf;";
            (my $perfUsername = $clientUsername) =~ s/\./\-/g;
            $perf .= " '$perfUsername-num-clients'=$numClients '$perfUsername-num-clients-web'=$numClientsWeb".
            " '$perfUsername-num-clients-smf'=$numClientsSmf";
        }

        #if (! defined($name) ) {
        #   fail("No username found");
        #}

        print $ERROR{$exitStatus} . '.' . $crit . $output . ' |' . $perf . "\n";
        exit $exitStatus;
    } else {
        fail($req->{error});
    }
}

elsif ($opt{mode} eq 'vpn') {
    $opt{warning} ||= 50;
    $opt{critical} ||= 95;

    $opt{vpn} ||= $opt{name};

    if (! $opt{vpn} ) {
        print "Message-vpn not defined\n";
        exit $CODE{CRITICAL};
    }

    my $req = $semp->getMessageVpnStats(name => $opt{vpn});
    if (! $req->{error} ) {
        my $enabled = $req->{result}->{enabled}->[0];
        my $operational = $req->{result}->{operational}->[0];
        my $status = $req->{result}->{'local-status'}->[0];
        my $uniqueSubscriptions = $req->{result}->{'unique-subscriptions'}->[0];
        my $maxSubscriptions = $req->{result}->{'max-subscriptions'}->[0];
        my $connections = $req->{result}->{'connections'}->[0];
        my $maxConnections = $req->{result}->{'max-connections'}->[0];
        my $connSMF = $req->{result}->{'connections-service-smf'}->[0];
        my $connWEB = $req->{result}->{'connections-service-web'}->[0];
        my $connMQTT = $req->{result}->{'connections-service-mqtt'}->[0];
        my $ingressRate = $req->{result}->{'average-ingress-rate-per-minute'}->[0];
        my $egressRate = $req->{result}->{'average-egress-rate-per-minute'}->[0];
        my $ingressByteRate = $req->{result}->{'average-ingress-byte-rate-per-minute'}->[0];
        my $egressByteRate = $req->{result}->{'average-egress-byte-rate-per-minute'}->[0];
        my $ingressDiscards = $req->{result}->{'total-ingress-discards'}->[0];
        my $egressDiscards = $req->{result}->{'total-egress-discards'}->[0];

        if (! defined $enabled) {
            print "Message VPN $opt{name} not known\n";
            exit $CODE{CRITICAL};
        }

        if ($enabled eq 'true' && $operational eq 'true' && $status eq 'Up') {
            my $connUsage = 0;
            if ($maxConnections > 0) {
                $connUsage = sprintf("%.2f",$connections / $maxConnections);
            }
            my $subscrUsage = 0;
            if ($maxSubscriptions > 0) {
                $subscrUsage = sprintf("%.2f",$uniqueSubscriptions / $maxSubscriptions);
            }
            if ($connUsage >= $opt{critical} || $subscrUsage >= $opt{critical}) {
                $exitStatus = $CODE{CRITICAL};
            } elsif ($connUsage >= $opt{warning} || $subscrUsage >= $opt{warning}) {
                $exitStatus = $CODE{WARNING};
            }
            print $ERROR{$exitStatus}.". Subscriptions $uniqueSubscriptions/$maxSubscriptions, ".
            "Connections $connections/$maxConnections | 'unique-subscriptions'=$uniqueSubscriptions ".
            "'subscriptions-usage'=$subscrUsage%;$opt{warning};$opt{critical} 'connections'=$connections ".
            "'conn-usage'=$connUsage%;$opt{warning};$opt{critical} ".
            "'conn-smf'=$connSMF 'conn-web'=$connWEB 'conn-mqtt'=$connMQTT ".
            "'ingress-rate'=$ingressRate 'egress-rate'=$egressRate 'ingress-byte-rate'=$ingressByteRate ".
            "'egress-byte-rate'=$egressByteRate 'ingress-discards'=$ingressDiscards 'egress-discards'=$egressDiscards\n";
        } else {
            print "CRITICAL. Enabled: $enabled, Operational: $operational, Status: $status\n";
            exit $CODE{CRITICAL};
        }
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
#        my @mandatoryStats = ('current-spool-usage-mb', 'current-messages-spooled', 'maximum-spool-usage-mb');
#        my @optionalStats = ('maximum-queues-and-topic-endpoints', 'current-queues-and-topic-endpoints', 'maximum-egress-flows', 'current-egress-flows', 'maximum-ingress-flows', 'current-ingress-flows', 'maximum-transactions', 'current-transactions', 'maximum-transacted-sessions', 'current-transacted-sessions');
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
       print $ERROR{$exitStatus}.".".$output."|".$perf;
    } else {
        fail($req->{error});
    }
}
elsif ($opt{mode} eq 'queue' || $opt{mode} eq 'topic-endpoint') {
    $opt{warning}  ||= 500;
    $opt{critical} ||= 1000;

    $opt{name} ||= '*';
    $opt{vpn}  ||= '*';

    my $req = $semp->getEndpoints(vpn => $opt{vpn}, name => $opt{name}, endpoint => $opt{mode});
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
       print $ERROR{$exitStatus}.". Total ".$upEndpoints." ".$opt{mode}."s.".$output."|".$perf;
    } else {
        fail($req->{error});
    }

}
else {
    fail("Invalid mode ".$opt{mode});
}

sub fail {
    my $text = shift;
    print $text;
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

sub help {
    my $me = basename($0);
    print qq{Usage: $me -H host -V version -m mode [ -p port ] [ -u username ]
                        [ -P password ] [ -v vpn ] [ -n name ] [ -t ] [ -D ]
                        [ -w warning ] [ -c critical ]

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
 -t,  --tls             SEMP service is encrypted with TLS
 -D,  --debug           debug mode

Limit options:
  -w value, --warning=value   the warning threshold, range depends on the action
  -c value, --critical=value  the critical threshold, range depends on the action

Modes:
  redundancy
  config-sync
  alarm (deprecated after 7.2)
  raid
  disk
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
