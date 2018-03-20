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

use Data::Dumper;

$ENV{'PERL_LWP_SSL_VERIFY_HOSTNAME'} = 0;

our %entryIDs = ( 'message-vpn'     => 'vpn-name',
                  'client'          => 'name',
                  'client-username' => 'name',
                  'storage-element' => 'pattern',
                  'interface'       => 'phy-interface' );

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
    $args{debug} ||= 0;

    my $basic =  encode_base64($args{username}.":".$args{password});
    my $ua = $args{ua} || LWP::UserAgent->new;
    $ua->timeout(2);

    my $schema = ($args{tls})?'https':'http';

    my $self = { host => $args{host},
                 port => $args{port},
                 basic => $basic,
                 version => $args{version},
                 ua => $ua,
                 schema => $schema,
                 tls => $args{tls},
                 debug => $args{debug}
               };

    bless $self, $class;
}

sub genRPC {
    my $str = shift;
    my $version = shift;
    my $xml="<rpc semp-version=\"soltr/$version\">##DATA##</rpc>";
    my @words = split ' ', $str;
    my $entryIdDefined = 0;
    while (my $word = shift @words) {
        my $tag = "<$word>##DATA##</$word>";
        if (defined $entryIDs{$word}) {
            if ($entryIdDefined) {
                $tag = "##DATA##";
            }
            $entryIdDefined = 1;
            my $id = shift @words;
            if ($id) {
                $tag =~ s/##DATA##/<$entryIDs{$word}>$id<\/$entryIDs{$word}>##DATA##/;
            }
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
        my $error = 0;
        my $result = handleXml($response->decoded_content);
        if (defined $result->{'parse-error'}) {
            $error = $result->{'parse-error'}->[0];
        }
        my %ret = ( "error" => $error, "result" => handleXml($response->decoded_content), "raw" => $response->decoded_content );
        return \%ret;
    } else {
        print "Got error while sending request".$response->status_line."\n" if ($self->{debug});
        print $response->decoded_content."\n" if ($self->{debug});
        my %ret = ( "error" => "Error connecting to server. ".$response->status_line, "result" => $response->decoded_content );
        return \%ret;
    }
}

sub handleXml {
    my $xml = shift;
    my %hash;
    while ($xml =~ /<([^<>]+)>([^<>]*)<\/\1>/g) {
        #$hash{$1} = $2;
        push @{$hash{$1}}, $2;
    }
    return \%hash;
}

# This sub counts the mount of top-level children inside the appropriate tag
sub countChildren {
    my $xml = shift;
    my $tag = shift;

    if ($xml =~ /<$tag>(.*?<([^<>]+)>.*?)<\/$tag>/s) {
        my $content = $1;
        my $child = $2;
        my $count = () = $content =~ /<$child>/g;
        return $count;
    }
    return 0;
}




sub getMessageVpnStats {
    my $self = shift;
    my %args = @_;

    unless ($args{name}) {
        croak 'name parameter is required';
    }

    my $rpc = genRPC("show message-vpn ".$args{name}." stats", $self->{version});
    my $req = sendRequest($self, $rpc);
    return $req;
}

sub getRedundancy {
    my $self = shift;

    my $rpc = genRPC("show redundancy", $self->{version});
    my $req = sendRequest($self, $rpc);
    return $req;
}

sub getConfigSync {
    my $self = shift;

    my $rpc = genRPC("show config-sync", $self->{version});
    my $req = sendRequest($self, $rpc);
    return $req;
}

sub getAlarm {
    my $self = shift;

    my $rpc = genRPC("show alarm", $self->{version});
    my $req = sendRequest($self, $rpc);
    if ($req->{error}) {
        return $req->{error};
    }
    if (defined $req->{result}->{alarm}->[0] && $req->{result}->{alarm}->[0] =~ /^\s+$/) {
        return '';
    }
    return join ',', map { $_.": ".$req->{result}->{$_}->[0] } keys %{$req->{result}->[0]};
}

sub getRaid {
    my $self = shift;
    #$self->{debug} = 1;
    my $rpc = genRPC("show disk", $self->{version});
    my $req = sendRequest($self, $rpc);
    return $req;
}

sub getDiskUsage {
    my $self = shift;
    my $rpc = genRPC("show disk detail", $self->{version});
    my $req = sendRequest($self, $rpc);
    return $req;
}

sub getStorageElement {
    my $self = shift;
    my $rpc = genRPC("show storage-element *", $self->{version});
    my $req = sendRequest($self, $rpc);
    return $req;
}

sub getMemoryUsage {
    my $self = shift;
    my $rpc = genRPC("show memory", $self->{version});
    my $req = sendRequest($self, $rpc);
    return $req;
}

sub getEnvironment {
    my $self = shift;
    my $rpc = genRPC("show environment", $self->{version});
    my $req = sendRequest($self, $rpc);
    return $req;
}

sub getInterface {
    my $self = shift;
    my %args = @_;

    unless ($args{name}) {
        croak 'name parameter is required';
    }

    my $rpc = genRPC("show interface ".$args{name}, $self->{version});
    my $req = sendRequest($self, $rpc);
    if (! $req->{error} && defined $req->{result}->{mode}->[0]) {
        $req->{result}->{'operational-members'} = countChildren($req->{raw}, 'operational-members');
    }
    return $req;
}

sub getClientStats {
    my $self = shift;
    my $rpc = genRPC("show stats client", $self->{version});
    my $req = sendRequest($self, $rpc);
    return $req;
}

sub getVpnClientStats {
    my $self = shift;
    my %args = @_;

    unless ($args{name}) {
        croak 'name parameter is required';
    }
    unless ($args{vpn}) {
        croak 'vpn parameter is required';
    }

    my $rpc = genRPC("show client ".$args{name}." message-vpn ".$args{vpn}." stats", $self->{version});
    print $rpc if ($self->{debug});
    my $req = sendRequest($self, $rpc);
    return $req;
}

sub getVpnClientDetail {
    my $self = shift;
    my %args = @_;

    unless ($args{name}) {
        croak 'name parameter is required';
    }
    unless ($args{vpn}) {
        croak 'vpn parameter is required';
    }

    my $rpc = genRPC("show client ".$args{name}." message-vpn ".$args{vpn}." detail", $self->{version});
    print $rpc if ($self->{debug});
    my $req = sendRequest($self, $rpc);
    return $req;
}


sub getVpnClientUsernameStats {
    my $self = shift;
    my %args = @_;

    unless ($args{name}) {
        croak 'name parameter is required';
    }
    unless ($args{vpn}) {
        croak 'vpn parameter is required';
    }

    my $rpc = genRPC("show client-username ".$args{name}." message-vpn ".$args{vpn}." stats", $self->{version});
    print $rpc if ($self->{debug});
    my $req = sendRequest($self, $rpc);
    return $req;
}


1;
