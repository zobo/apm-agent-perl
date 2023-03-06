# Extremely simple Elastic APM Agent for PERL

A very basic APM agent for PERL. Create a transaction and spans and error objects and send them to Elastic APM ingest.

## Simple example

```perl
my $a = Apm->new({});
$a->make_meta;
$a->start_tx("test_name2", "cron");
usleep(100);
$a->start_span("span1","db.mysql");
usleep(100);
$a->start_span("span2");
usleep(100);
$a->end_span;
usleep(100);
my $x = $a->make_error("TEST ERRROR2");
usleep(100);
$a->end_span;
$a->end_tx;
a->send;
```

## Options

The agent is configured via constructor object or $ENV. See source for options.

## Example for Perl Dancer

```perl
hook 'before' => sub {
  my $apm = Apm->new({});
  $apm->make_meta;
  $apm->start_tx(request->method." ".request->path_info, 'request');
  $apm->parse_trace_header(request->header('ELASTIC-APM-TRACEPARENT') || '');
  $apm->parse_trace_header(request->header('TRACEPARENT') || '');
  $apm->{tx}->{context}->{request} = {
    method  => request->method,
    url     => { full => substr("http://" . request->{host} . request->{env}->{REQUEST_URI}, 0, 1024), },
    headers => {
      'user-agent' => request->{user_agent},
      'x-forwarded-for' => request->headers->{'x-forwarded-for'},
    },
  };
  var apm => $apm;
};

hook 'after' => sub {
  my $response = shift;
  my $apm = vars->{apm};
  if ($response->status >= 200 && $response->status < 300) {
    $apm->{tx}->{outcome} = "success";
    $apm->{tx}->{result} = "HTTP 2xx";
  } else {
    $apm->{tx}->{outcome} = "failure";
    $apm->{tx}->{result} = "HTTP ".$response->status;
  }
  $apm->{tx}->{context}->{response} = { status_code => $response->status };
  $apm->end_tx;
  $apm->send;
};

hook 'on_handler_exception' => sub {
  my $exception = shift;
  my $apm = vars->{apm};
  $apm->make_error($exception);
  $apm->{tx}->{outcome} = "failure";
  $apm->end_tx;
  $apm->send;
};

hook 'before_template_render' => sub {
  vars->{apm}->start_span("template_render");
};

hook 'after_template_render' => sub {
  vars->{apm}->end_span;
};
```

## Example for wrapping object calls

This example shows how to "wrap" some class calls without using any (unusual)
dependencies. `vars` is Perl Dancer specific and can be replaced by some other
means of getting the current `apm` object.
The class calls that are wrapped must be imported via `use` in the same perl module.

Code inspired by [Wrap::Sub](https://metacpan.org/pod/Wrap::Sub).

```perl
use Symbol;
use WebService::Solr;
use DBI;

{
  no warnings 'redefine';

  foreach my $fname (qw(WebService::Solr::generic_solr_request WebService::Solr::search)) {
    my $glob = qualify_to_ref($fname => scalar caller);
    my $orig = \&$glob;
    my $wrap = sub {
      my @arg = @_;
      vars->{apm}->start_span($fname." ".$arg[1],"db.solr")->{context}->{db} = { 'statement' => substr(Dumper($arg[2]), 0, 2048), 'type' => 'solr' };
      my $ret = &$orig(@arg);
      vars->{apm}->end_span;
      return $ret;
    };
    *$glob = $wrap;
  }
}

{
  no warnings 'redefine';

  foreach my $fname (qw(DBI::db::selectall_arrayref DBI::db::quick_select DBI::db::selectrow_array DBI::db::selectrow_hashref)) {
    my $glob = qualify_to_ref($fname => scalar caller);
    my $orig = \&$glob;
    my $wrap = sub {
      my @arg = @_;
      vars->{apm}->start_span($fname,"db.mysq")->{context}->{db} = { 'statement' => substr(Dumper($arg[1]), 0, 2048), 'type' => 'mysql' };
      my $ret = &$orig(@arg);
      vars->{apm}->end_span;
      return $ret;
    };
    *$glob = $wrap;
  }
}
```

# License

MIT

# Contact

Open an issue, send me an email or ping me on Twitter [@damjancvetko](https://twitter.com/damjancvetko).
