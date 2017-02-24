#!/usr/bin/perl

use Solace::SEMP;
use Data::Dumper;

my $semp = Solace::SEMP->new( host => '10.101.2.115', port => '8080', version => '7.2' );
my $req = $semp->getMessageVpnStats(name => "webtrader-ICONS");
if (! $req->{error} ) {
	print "Total Unique Subscriptions: ".$req->{result}->{'total-unique-subscriptions'}."\n";
	print "Average Ingress Rate: ".$req->{result}->{'average-ingress-byte-rate-per-minute'}." (Bytes/min)\n";
}

#print Dumper($req);
