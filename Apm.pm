#
# Copyright (C) 2023 Damjan Cvetko
#

package Apm;

use strict;
use warnings;

use POSIX;
use JSON;
use Time::HiRes qw(time);
use Data::Dumper;
use LWP::UserAgent;

sub new {
    my ( $class, $args ) = @_;
    my $self = bless {
        service_name => $args->{name}
          || $ENV{ELASTIC_APM_SERVICE_NAME}
          || undef,
        service_version => $args->{version}
          || $ENV{ELASTIC_APM_SERVICE_VERSION}
          || undef,
        service_env => $args->{env}
          || $ENV{ELASTIC_APM_ENVIRONMENT}
          || $ENV{ENVIRONMENT}
          || undef,
        hostname => $args->{hostname} || $ENV{ELASTIC_APM_HOSTNAME}   || undef,
        url      => $args->{url}      || $ENV{ELASTIC_APM_SERVER_URL} || undef,
        meta     => '',
        events   => '',
        spans    => [],
    }, $class;

}

# https://github.com/elastic/apm-server/blob/72d58a75c8d155bfcfbd3db3ccf2d1ead56b2e64/docs/spec/v2/metadata.json

sub make_meta {
    my $self = shift;

    my ( $sysname, $nodename, $release, $version, $machine ) = POSIX::uname();

    my $meta = {
        metadata => {
            service => {
                name        => $self->{service_name},
                version     => $self->{service_version},
                environment => $self->{service_env},
                agent       => {
                    name    => "monotek-apm-perl",
                    version => "0.1",
                },
                language => {
                    name    => "perl",
                    version => "$^V",
                },
            },
            process => {
                pid => $$,
            },
            system => {
                hostname => $self->{hostname} ? $self->{hostname} : $nodename,
                architecture => $machine,
                platform     => $sysname,
            }
        },
    };
    $self->{meta} = encode_json $meta;
}

sub make_id {
    my ($count) = @_;

    my $id = "";
    $id .= [ '0' .. '9', 'a' .. 'f' ]->[ rand 16 ] for 1 .. $count;
    return $id;
}

sub parse_trace_header {
    my ( $self, $d ) = @_;

    # $d = "00-00112233445566778899aabbccddeeff-0011223344556677-00";
    if ( $d =~ /^00-([a-f\d]{32})-([a-f\d]{16})-[a-f\d]{2}$/ ) {
        ( $self->{tx}->{trace_id}, $self->{tx}->{parent_id} ) = ( $1, $2 );
    }
}

# https://github.com/elastic/apm-server/blob/72d58a75c8d155bfcfbd3db3ccf2d1ead56b2e64/docs/spec/v2/transaction.json

sub start_tx {
    my ( $self, $name, $type ) = @_;

    $self->{tx} = {
        id         => make_id(16),
        parent_id  => undef,
        trace_id   => make_id(32),
        name       => substr( $name, 0, 1024 ),
        type       => substr( $type, 0, 1024 ),
        timestamp  => int( time * 1000000 ),
        span_count => { started => 0 },
    };
}

sub end_tx {
    my ($self) = @_;

    # finish spans
    while ( @{ $self->{spans} } ) {
        $self->end_span;
    }

    $self->{tx}->{duration} =
      ( int( time * 1000000 ) - $self->{tx}->{timestamp} ) / 1000;

    my $json = encode_json { transaction => $self->{tx} };

    $self->{events} .= "\n" . $json;
    return $json;
}

# https://github.com/elastic/apm-server/blob/72d58a75c8d155bfcfbd3db3ccf2d1ead56b2e64/docs/spec/v2/span.json

sub start_span {
    my ( $self, $name, $type ) = @_;
    $type = $type || "custom";

    my $span = {
        id        => make_id(16),
        parent_id => (
            scalar @{ $self->{spans} }
            ? $self->{spans}[0]->{id}
            : $self->{tx}->{id}
        ),
        trace_id  => $self->{tx}->{trace_id},
        name      => $name,
        type      => $type,
        timestamp => int( time * 1000000 ),

    };

    unshift( @{ $self->{spans} }, $span );

    return $span;
}

sub end_span {
    my ($self) = @_;

    if ( @{ $self->{spans} } ) {

        my $span = shift( @{ $self->{spans} } );
        $span->{duration} =
          ( int( time * 1000000 ) - $span->{timestamp} ) / 1000;

        my $json = encode_json { span => $span };

        $self->{events} .= "\n" . $json;
        return $json;
    }

    # broken

}

# https://github.com/elastic/apm-server/blob/72d58a75c8d155bfcfbd3db3ccf2d1ead56b2e64/docs/spec/v2/error.json

sub make_error {
    my ( $self, $message ) = @_;

    $message =~ s/^\s+|\s+$//g;

    my $error_id = make_id(32);
    my ( $trace_id, $parent_id, $transaction_id ) = ( undef, undef, undef );
    if ( $self->{tx} ) {
        $trace_id  = $self->{tx}->{trace_id};
        $parent_id = (
            @{ $self->{spans} }
            ? $self->{spans}[0]->{id}
            : $self->{tx}->{id}
        );
        $transaction_id = $self->{tx}->{id};
    }

    my @stack = $self->get_stack;
    my $error = {
        error => {
            id             => $error_id,
            parent_id      => $parent_id,
            trace_id       => $trace_id,
            transaction_id => $transaction_id,

            timestamp => int( time * 1000000 ),

            # context => { },
            # culprit => { },
            exception => {
                message    => $message,
                stacktrace => \@stack,
            },

            # log => { },
        },
    };

    my $json = encode_json $error;

    $self->{events} .= "\n" . $json;

    return $json;
}

sub get_stack {
    my ($self) = @_;
    my @stack;

    my $deepness = 0;
    while ( my ( $package, $file, $line ) = caller( $deepness++ ) ) {
        push @stack, { filename => $file, lineno => $line, module => $package };
    }

    return @stack;
}


sub send {
    my $self = shift;

    my $url = $self->{url} ? $self->{url} : 'http://127.0.0.1:8200';

    my $req = HTTP::Request->new( 'POST', $url . '/intake/v2/events' );
    $req->header( 'Content-Type' => 'application/x-ndjson' );
    $req->header( 'User-Agent'   => 'elasticapm-perl/1.0' );
    $req->header( 'Accept'       => 'application/json' );
    $req->content( $self->{meta} . $self->{events} );

    #debug "\n";
    #debug Dumper($req);

    my $lwp = LWP::UserAgent->new;
    my $ret = $lwp->request($req);

    #debug Dumper($ret);
    #debug Dumper(%ENV);
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Apm - Extremely simple Elastic APM Agent for PERL

=head1 VERISON

version 0.1

=head1 SYNOPSIS

 use Apm;

 my $apm = Apm->new({});
 $apm->make_meta;
 $apm->start_tx("TX NAME", "request");
 $apm->start_span("span1");
 $apm->start_span("span2", "db.mysql");
 $apm->end_span;
 $apm->make_error("Error Text");
 $apm->end_span;
 $apm->end_tx;
 $apm->send;

=head1 DESCRIPTION

This module is a implementation of a very simple Elastic APM Agent for PERL.
It support configuration over ENV or constructor object values. It can create one
transaction and multiple spans, where nesting of spans is doens automatically.

=head1 METHODS

=over

=item Apm<new>

Creates a new Apm agent instance. It configures the agent from $ENV or the optional $options object.

 my $apm = Apm->new({
     # Optional
     service_name    => # Name of the service reported, $ENV{ELASTIC_APM_SERVICE_NAME}
     service_version => # Version of service reported, $ENV{ELASTIC_APM_SERVICE_VERSION}
     service_env     => # Service environment reported, $ENV{ELASTIC_APM_ENVIRONMENT}, $ENV{ENVIRONMENT}
     hostname        => # Hostname reported, $ENV{ELASTIC_APM_HOSTNAME}, POSIX::uname()->nodename
     url             => # APM ingest URL, $ENV{ELASTIC_APM_SERVER_URL}
 });

=item Apm<make_meta>

 $apm->make_meta;

Constructs the metadata object that will be sent to APM ingest. The method uses the provided configuration
and POSIX::uname() to fill the stucture.

See https://github.com/elastic/apm-server/blob/72d58a75c8d155bfcfbd3db3ccf2d1ead56b2e64/docs/spec/v2/metadata.json

=item Apm<start_tx>($name, $type)

Creates a new transaction with $name and $type.

See https://github.com/elastic/apm-server/blob/72d58a75c8d155bfcfbd3db3ccf2d1ead56b2e64/docs/spec/v2/transaction.json

 $apm->start_tx("transaction name", "request");

=item Apm<parse_trace_header>($d)

Parses the distributed tracing header.
THIS SHOULD BE CALLED AFTER start_tx

 $apm->parse_trace_header("00-00112233445566778899aabbccddeeff-0011223344556677-00");

=item Apm<end_tx>

Finishes transaction and calcualtes duration.

 $apm->end_tx;

=item Apm<start_span>($name, $type)

Creates a new span. Should be called after start_tx. If a span is already active the current span is
referenced as its parent.

See https://github.com/elastic/apm-server/blob/72d58a75c8d155bfcfbd3db3ccf2d1ead56b2e64/docs/spec/v2/span.json

 $apm->start_span("span 1", "db.mysql");

=item Apm<end_span>

Finishes current span and calculates the duration.

 $apm->end_span;

=item Apm<make_error>($message)

Creates an error structure. If a span is already active, the error will refernece it as its parent.
A Stack trace is also created.

See https://github.com/elastic/apm-server/blob/72d58a75c8d155bfcfbd3db3ccf2d1ead56b2e64/docs/spec/v2/error.json

 $apm->make_error("Error Message");

=item Apm<send>

Sends the accumulated objects to APM ingest.

=back
