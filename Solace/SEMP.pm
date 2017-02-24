package Solace::SEMP;

#
# Needs perl-LWP-Protocol-https
#

use vars qw($VERSION @ISA);
use warnings;
use strict;

use version; 
our $VERSION = qv('0.1');

use Carp;
use LWP::UserAgent;
use MIME::Base64;

sub new {
    my $class = shift;
    my %args = @_;

    unless ($args{host}) {
        croak 'host parameter is required';
    }
    unless ($args{version}) {
        croak 'version parameter is required';
    }

    $args{port} ||= 80;
    $args{username} ||= 'admin';
    $args{password} ||= 'admin';
    $args{version} =~ s/\./\_/g;
    $args{tls} ||= 0;

    my $basic =  encode_base64($args{username}.":".$args{password});
    my $ua = $args{ua} || LWP::UserAgent->new;
    my $schema = ($args{tls})?'https':'http';

    my $self = { host => $args{host}, 
                 port => $args{port}, 
                 basic => $basic, 
                 version => $args{version}, 
                 ua => $ua,
                 schema => $schema,
                 tls => $args{tls}
               };

    bless $self, $class;
}

sub genRPC {
    my $str = shift;
    my $version = shift;
    my $xml="<rpc semp-version=\"soltr/$version\">##DATA##</rpc>";
    my @words = split ' ', $str;
    while (my $word = shift @words) {
        my $tag = "<$word>##DATA##</$word>";
        if ($word eq "message-vpn") {
            my $vpnName = shift @words;
            $tag =~ s/##DATA##/<vpn-name>$vpnName<\/vpn-name>##DATA##/;
        }
        $xml =~ s/##DATA##/$tag/;
    }
    $xml =~ s/##DATA##//;
    return $xml;
}

sub sendRequest {
    my $self = shift;
    my $content = shift;
    my $response = $self->{ua}->post($self->{schema}."://".$self->{host}.":".$self->{port}."/SEMP", 
                Authorization => 'Basic '.$self->{basic}, 
                'Content' => $content);
    if ($response->is_success) {
        print $response->status_line."\n" if ($self->{debug});
        print $response->decoded_content."\n" if ($self->{debug});
        my %ret = ( "error" => 0, "result" => handleXml($response->decoded_content) );
        return \%ret;
    } else {
        print "Got error while sending request\n";
        print $response->status_line."\n";
        print $response->decoded_content."\n";
        return ( "error" => $response->status_line, "result" => $response->decoded_content );
    }
}

sub handleXml {
    my $xml = shift;
    my %hash;
    while ($xml =~ /<([^<>]+)>([^<>]*)<\/\1>/g) {
        $hash{$1} = $2;
    }
    return \%hash;
}



sub getMessageVpnStats {
    my $self = shift;
    my %args = @_;

    unless ($args{name}) {
        croak 'name parameter is required';
    }

    my $content = genRPC("show message-vpn ".$args{name}." stats", $self->{version});
    my $req = sendRequest($self, $content);
    return $req;
}

1;
