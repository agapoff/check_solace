#!/usr/bin/env perl
##########################
# Perform checks against Solace Message Routers
# Designed for usage with Nagios, Icinga, Shinken... Whatever.
#
# Vitaly Agapov <v.agapov@quotix.com>
# 2017/02/27
# Last modified:
##########################

use strict;
use warnings;
use Getopt::Long qw/GetOptions/;
use Solace::SEMP;
use Data::Dumper qw/Dumper/;

our $VERSION = '0.01';
our %CODE=( OK => 0, WARNING => 1, CRITICAL => 2, UNKNOWN => 3 );
our %ERROR=( 0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN' );

&help if ! @ARGV;
our %opt;
GetOptions(
    \%opt,
    'help|h',
    'warning=s',
    'critical=s',
    'version|V=s',
    'mode|m=s',
	'name|n=s',
    'host|H=s',
    'port|p=s',
    'username|u=s',
    'password=s',
    'debug|D'
);

&help if (! $opt{host});

my $semp = Solace::SEMP->new( %opt );

my $exitStatus = $CODE{OK};

if ($opt{mode} eq 'redundancy') {
    my $req = $semp->getRedundancy;
    if (! $req->{error} ) {
        my $configStatus = $req->{result}->{'config-status'}->[0];
		my $redundancyStatus = $req->{result}->{'redundancy-status'}->[0];
		my $redundancyMode = $req->{result}->{'redundancy-mode'}->[0];
		my $mate = $req->{result}->{'mate-router-name'}->[0];
        if ($configStatus ne 'Enabled' || $redundancyStatus ne 'Up') {
		    $exitStatus = $CODE{CRITICAL};
		}
        print $ERROR{$exitStatus}.". Config: $configStatus, Status: $redundancyStatus, Mode: $redundancyMode, Mate: $mate\n";
		exit $exitStatus;
    } else {
	    fail($req->{error});
    }
}
elsif ($opt{mode} eq 'alarm') {
    my $req = $semp->getAlarm;
    if ($req) { 
	    print $req."\n";; 
		exit $CODE{CRITICAL};
	} else { 
	    print "OK. No alarms\n"; 
        exit $CODE{OK}		
	}
}
elsif ($opt{mode} eq 'raid') {
    my $req = $semp->getRaid;
    if (! $req->{error} ) {
        my $raidState = $req->{result}->{'raid-state'}->[0];
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
			push @perfdata,"'$mountPoint'=$usage%;$opt{warning}%;$opt{critical}%";
        }
		my $perfdataOut = join ', ',@perfdata;
        print $ERROR{$exitStatus}.". ".$output." | ".$perfdataOut."\n";
		exit $exitStatus;
    } else {
        fail($req->{error});
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
        print $ERROR{$exitStatus}.". Physical mem usage $physMemUsage%. Subscriptions mem usage $subscrMemUsage% | 'physical-memory-usage'=$physMemUsage%;$opt{warning};$opt{critical}, 'subscription-memory-usage'=$subscrMemUsage%;$opt{warning};$opt{critical}\n";
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
        $output .= " | 'rx-bytes'=$rxBytes, 'tx-bytes'=$txBytes, 'rx-pkts'=$rxPkts, 'tx-pkts'=$txPkts";
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
          "Discarded $ingressDiscards/$egressDiscards | 'connected'=$clients;$opt{warning};$opt{critical}, ".
          "'ingress-rate'=$ingressRate, 'egress-rate'=$egressRate, 'ingress-byte-rate'=$ingressByteRate, ".
          "'egress-byte-rate'=$egressByteRate, 'ingress-discards'=$ingressDiscards, 'egress-discards'=$egressDiscards\n";
		exit $exitStatus;
    } else {
        fail($req->{error});
    }
}
elsif ($opt{mode} eq 'vpn') {
    $opt{warning} ||= 50;
    $opt{critical} ||= 95;

    if (! $opt{name} ) {
        print "Message-vpn name not defined\n";
        exit $CODE{CRITICAL};
    }

    my $req = $semp->getMessageVpnStats(name => $opt{name});
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
             "Connections $connections/$maxConnections | 'unique-subscriptions'=$uniqueSubscriptions, ".
             "'subscriptions-usage'=$subscrUsage%, 'connections'=$connections, 'conn-usage'=$connUsage, ".
             "'conn-smf'=$connSMF, 'conn-web'=$connWEB, 'conn-mqtt'=$connMQTT, ". 
             "'ingress-rate'=$ingressRate, 'egress-rate'=$egressRate, 'ingress-byte-rate'=$ingressByteRate, ".
             "'egress-byte-rate'=$egressByteRate, 'ingress-discards'=$ingressDiscards, 'egress-discards'=$egressDiscards\n";
        } else {
            print "CRITICAL. Enabled: $enabled, Operational: $operational, Status: $status\n";
			exit $CODE{CRITICAL};
        }
	} else {
        fail($req->{error});
    }
}

sub fail {
    my $text = shift;
	print $text;
	exit $CODE{CRITICAL};
}

sub help {
    my $me = basename($0);
    print qq{Usage: $me <options>
Run checks against Solace Message Router using SEMP protocol.
Returns with an exit code of 0 (success), 1 (warning), 2 (critical), or 3 (unknown)
This is version $VERSION.

Common connection options:
 -H,  --host=NAME       hostname to connect to
 -p,  --port=NUM        port to connect to; defaults to 80.
 -u,  --username=NAME   management user to connect as; defaults to 'admin' 
 -P,  --password=PASS   management user password; defaults to 'admin'
 -V,  --version=NUM     Solace version (i.e. 8.0)
 -m,  --mode=STRING     test to perform
 -n,  --name=STRING     name of the interface or message-vpn to test (needed when the corresponding mode is selected)
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
  vpn
};
   exit 0;
}

#print Dumper($req);
