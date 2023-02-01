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
  $apm->start_tx(request->path_info, 'request');
  $apm->parse_trace_header(request->header('ELASTIC-APM-TRACEPARENT') || '');
  $apm->parse_trace_header(request->header('TRACEPARENT') || '');
  var apm => $apm;
};

hook 'after' => sub {
  my $apm = vars->{apm};
  $apm->end_tx;
  $apm->send;
};

hook 'on_handler_exception' => sub {
  my $exception = shift;
  my $apm = vars->{apm};
  $apm->make_error($exception);
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

# License

MIT

# Contact

Open an issue, send me an email or ping me on Twitter [@damjancvetko](https://twitter.com/damjancvetko).
