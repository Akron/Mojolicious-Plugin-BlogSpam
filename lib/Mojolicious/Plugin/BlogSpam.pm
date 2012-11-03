package Mojolicious::Plugin::BlogSpam;
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::URL;
use Mojo::JSON;
use Mojo::Log;
use Mojo::UserAgent;
use Scalar::Util qw/weaken/;

our $VERSION = '0.03';

# Todo: - Check for blacklist/whitelist/max words etc. yourself.
#       - Create a route condition for posts.
#         -> $r->post('/comment')->over('blogspam')->to('#');

# 'fail' is a special flag
our @OPTION_ARRAY =
  qw/blacklist exclude whitelist mandatory
     max-links max-size min-size min-words/;


# Register plugin
sub register {
  my ($plugin, $mojo, $params) = @_;

  $params ||= {};

  # Load parameter from Config file
  if (my $config_param = $mojo->config('BlogSpam')) {
    $params = { %$config_param, %$params };
  };

  # Set server url of BlogSpam instance
  my $url = Mojo::URL->new(
    delete $params->{url} || 'http://test.blogspam.net/'
  );

  # Set port of BlogSpam instance
  $url->port(delete $params->{port} || '8888');

  # Site name
  my $site = delete $params->{site};

  # Add Log
  my $log;
  if (my $log_path = delete $params->{log}) {
    $log = Mojo::Log->new(
      path => $log_path,
      level => delete $params->{log_level} || 'info'
    );
  };

  my $app_clone = $mojo;
  weaken $app_clone;

  # Get option defaults
  my (%options, $base_options);
  foreach ('fail', @OPTION_ARRAY) {
    $options{$_} = delete $params->{$_} if $params->{$_};
  };
  $base_options = \%options if %options;

  # Add 'blogspam' helper
  $mojo->helper(
    blogspam => sub {
      my $c = shift;
      my $obj = Mojolicious::Plugin::BlogSpam::Comment->new(
	url    => $url->to_string,
	log    => $log,
	site   => $site,
	app    => $app_clone,
	client => __PACKAGE__ . ' v' . $VERSION,
	base_options => $base_options,
	@_
      );

      # Get request headers
      my $headers = $c->req->headers;

      # Set user-agent if not given
      $obj->agent($headers->user_agent) unless $obj->agent;

      # No ip manually given
      unless ($obj->ip) {

	# Get forwarded ip
	if (my $ip = $headers->to_hash->{'X-Forwarded-For'}) {
	  $obj->ip( split(/\s*,\s*/, $ip) );
	}

	# Get host ip
	else {
	  $obj->ip( split(/\s*:\s*/, ($headers->host || '')) );
	};
      };

      return $obj;
    }
  );
};


# BlogSpam object class
package Mojolicious::Plugin::BlogSpam::Comment;
use Mojo::Base -base;

has [qw/comment ip email link name subject agent/];


# Test comment for spam
sub test_comment {
  my $self = shift;

  # Callback for async
  my $cb = pop if $_[-1] && ref $_[-1] && ref $_[-1] eq 'CODE';

  unless ($self->ip && $self->comment) {
    $self->{app}->log->debug('You have to specify ip and comment');
    return;
  };

  # Create option string
  my $option_string = $self->_options(@_);

  # Check for mandatory parameters
  while ($option_string &&
	   $option_string =~ m/(?:^|,)mandatory=([^,]+?)(?:,|$)/g) {
    return unless $self->{$1};
  };

  # Create option array if set
  my @options = (options => $option_string) if $option_string;

  # Push site to array if set
  push(@options, site => $self->{site}) if $self->{site};

  # Make xml-rpc call
  if ($cb) {

    # Make call non-blocking
    $self->_xml_rpc_call(
      testComment => (
	%{$self->hash},
	@options
      ) => sub {
	return $cb->( $self->_handle_test_response( shift ) );
      }
    );

    return -1;
  };

  # Make call blocking
  my $res = $self->_xml_rpc_call(
    testComment => (
      %{$self->hash},
      @options
    )
  );

  return $self->_handle_test_response($res);
};


# Handle test_comment response
sub _handle_test_response {
  my $self = shift;
  my $res  = shift;

  # No response
  return -1 unless $res;

  # Get response element
  my $response =
    $res->dom->at('methodResponse > params > param > value > string');

  # Unexpected response format
  return -1 unless $response;

  # Get response tag
  $response = $response->all_text;

  # Response string is malformed
  return -1 unless $response =~ /^(OK|ERROR|SPAM)(?:\:\s*(.+?))$/;

  # Comment is no spam
  return 1 if $1 eq 'OK';

  # Log is defined
  if (my $log = $self->{log}) {

    # Serialize comment
    my $msg = "[$1]: " . ($2 || '') . ' ' .
      Mojo::JSON->new->encode($self->hash);

    # Log error
    if ($1 eq 'ERROR') {
      $log->error($msg);
    }

    # Log spam
    else {
      $log->info($msg);
    };
  };

  # An error occured
  return -1 if $1 eq 'ERROR';

  # The comment is considered spam
  return if $1 eq 'SPAM';
};


# Classify a comment as spam or ham
sub classify_comment {
  my $self = shift;
  my $train = shift;

  # Callback for async
  my $cb = pop if $_[-1] && ref $_[-1] && ref $_[-1] eq 'CODE';

  # Missing comment and valid train option
  unless ($self->comment && $train && $train =~ /^(?:ok|spam)$/) {
    $self->{app}->log->debug('You have to specify comment and train');
    return;
  };

  # Create site array if set
  my @site = (site => $self->{site}) if $self->{site};

  # Send xml-rpc call
  if ($cb) {
    $self->_xml_rpc_call(classifyComment => (
      %{$self->hash},
      train => $train,
      @site => sub {
	my $res = shift;
	$cb->($res ? 1 : 0);
      }
    ));

    return;
  };

  return 1 if $self->_xml_rpc_call(classifyComment => (
    %{$self->hash},
    train => $train,
    @site
  ));

  return;
};


# Get a list of plugins installed at the BlogSpam instance
sub get_plugins {
  my $self = shift;

  # Callback for async
  my $cb = pop if $_[-1] && ref $_[-1] && ref $_[-1] eq 'CODE';

  # Response of xml-rpc call
  if ($cb) {

    # Non-blocking request
    $self->_xml_rpc_call(
      getPlugins => sub {
	my $res = shift;
	return $cb->($self->_handle_plugins_response($res));
      });

    return ();
  };

  # Blocking request
  my $res = $self->_xml_rpc_call('getPlugins');
  return $self->_handle_plugins_response($res);
};


# Handle get_plugins response
sub _handle_plugins_response {
  my $self = shift;
  my $res = shift;

  # Retrieve result
  my $array =
    $res->dom->at('methodResponse > params > param > value > array > data');

  # No plugins installed
  return () unless $array;

  # Convert data to array
  return @{$array->find('string')->map(sub { $_->text })};
};


# Get statistics of your site from the BlogSpam instance
sub get_stats {
  my $self = shift;

  # Callback for async
  my $cb = pop if $_[-1] && ref $_[-1] && ref $_[-1] eq 'CODE';

  my $site = shift || $self->{site};

  # No site is given
  return unless $site;

  # Send xml-rpc call
  if ($cb) {

    # Send non-blocking request
    my $res = $self->_xml_rpc_call(
      'getStats', $site => sub {
	my $res = shift;
	return $cb->($self->_handle_stats_response($res));
      });

    return;
  };

  # Send blocking request
  my $res = $self->_xml_rpc_call('getStats', $site);
  return $self->_handle_stats_response($res);
};


# Handle get_stats response
sub _handle_stats_response {
  my $self = shift;
  my $res = shift;

  # Get response struct
  my $hash =
    $res->dom->at('methodResponse > params > param > value > struct');

  # No response struct defined
  return {} unless $hash;

  # Convert struct to hash
  return {@{$hash->find('member')->map(
    sub {
      return ($_->at('name')->text, $_->at('value > int')->text);
    })}};
};


# Get a hash representation of the comment
sub hash {
  my $self = shift;
  my %hash = %$self;

  # Delete non-comment info
  delete @hash{qw/site app url log client base_options/};

  # Delete empty values
  return { map {$_ => $hash{$_} } grep { $hash{$_} } keys %hash };
};


# Get options string
sub _options {
  my $self = shift;
  my %options = @_;

  # Create option string
  my @options;
  if (%options || $self->{base_options}) {

    # Get base options from plugin registration
    my $base = $self->{base_options};

    # Check for fail flag
    if (exists $options{fail}) {
      push(@options, 'fail') if $options{fail};
    }

    # Check for fail flag in plugin defaults
    elsif ($base->{fail}) {
      push(@options, 'fail');
    };

    # Check for valid option parameters
    foreach my $n (@Mojolicious::Plugin::BlogSpam::OPTION_ARRAY) {

      # Option flag is not set
      next unless $options{$n} || $base->{$n};

      # Base options
      my $opt = [
	$base->{$n} ? (ref $base->{$n} ? @{$base->{$n}} : $base->{$n}) : ()
      ];

      # Push new options
      push(
	@$opt,
	$options{$n} ? (ref $options{$n} ? @{$options{$_}} : $options{$n}) : ()
      );

      # Option flag is set as an array
      push(@options, "$n=$_") foreach @$opt};
  };

  # return option string
  return join(',', @options) if @options;
  return;
};


# Send xml-rpc call
sub _xml_rpc_call {
  my $self = shift;

  # Callback for async
  my $cb = pop if ref $_[-1] && ref $_[-1] eq 'CODE';

  my ($method_name, $param) = @_;

  # Create user agent
  my $ua = Mojo::UserAgent->new(
    max_redirects => 3,
    name => $self->{client}
  );

  # Start xml document
  my $xml = '<?xml version="1.0"?>' .
    "<methodCall><methodName>$method_name</methodName>";

  # Send with params
  if ($param) {
    $xml .= '<params><param><value>';

    # Param is a struct
    if (ref $param) {
      $xml .= '<struct>';

      # Create struct object
      foreach (keys %$param) {
	$xml .= "<member><name>$_</name><value>" .
	        '<string>' . $param->{$_} . '</string>' .
	        "</value></member>\n" if $param->{$_};
      };

      $xml .= '</struct>';
    }

    # Param is a string
    else {
      $xml .= "<string>$param</string>";
    };

    $xml .= '</value></param></params>';
  };

  $xml .= '</methodCall>';

  # Post method call to BlogSpam instance
  if ($cb) {

    # Post non-blocking
    $ua->post(
      $self->{url} => {} => $xml => sub {
	my $tx = pop;

	my $res = $tx->success;

	# Connection failure - accept comment
	unless ($res) {
	  $self->_log_error($tx);
	  return;
	};

	# Send response to callback
	$cb->($res);
	$ua = undef;
      });
    Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

    return;
  };

  # Post blocking
  my $tx = $ua->post($self->{url} => {} => $xml);
  my $res = $tx->success;

  # Connection failure - accept comment
  unless ($res) {
    $self->_log_error($tx);
    return;
  };

  # Return response
  return $res;
};


# Log connection_error
sub _log_error {
  my $self = shift;
  my $tx = shift;

  my ($err, $code) = $tx->error;
  $self->{app}->log->warn(
    'Connection error: [' . ($code || '*') . "] $code " .
      'for ' . $self->{url}
    );

  return;
};

1;


__END__

=pod

=head1 NAME

Mojolicious::Plugin::BlogSpam - Test your comments using BlogSpam


=head1 SYNOPSIS

  # In Mojolicious
  $app->plugin('BlogSpam');

  # In Mojolicious::Lite
  plugin 'BlogSpam';

  # In Controller
  my $blogspam = $c->blogspam(
    comment => 'I just want to test the system!'
  );

  # Check for spam
  if ($blogspam->test_comment) {
    print "Your comment is no spam!\n";
  };

  # Even non-blocking
  $blogspam->test_comment(sub {
    print "Your comment is no spam!\n" if shift;
  });

  # Train the system
  $blogspam->classify_comment('ok');


=head1 DESCRIPTION

L<Mojolicious::Plugin::BlogSpam> is a simple to test
comments or posts for spam against a
L<BlogSpam|http://blogspam.net/> instance
(see L<Blog::Spam::API> for the codebase).
It supports blocking as well as non-blocking requests.


=head1 METHODS

=head2 C<register>

  # Mojolicious
  $app->plugin(Blogspam => {
    url  => 'blogspam.sojolicio.us',
    port => '8888',
    site => 'http://grimms-abenteuer.de/',
    log  => '/spam.log',
    log_level => 'debug',
    exclude   => 'badip',
    mandatory => [qw/name subject/]
  });

  # Mojolicious::Lite
  plugin 'BlogSpam' => {
    site => 'http://grimms-abenteuer.de/'
  };

  # Or in your config file
  {
    BlogSpam => {
      url => 'blogspam.sojolicio.us',
      site => 'http://grimms-abenteuer.de/',
      port => '8888'
    }
  }

Called when registering the plugin.
Accepts the following optional parameters:

=over 2

=item C<url>

URL of your BlogSpam instance.
Defaults to C<http://test.blogspam.net/>.

=item C<port>

Port of your BlogSpam instance.
Defaults to C<8888>.

=item C<site>

The name of your site to monitor.

=item C<log>

A path to a log file.

=item C<log_level>

The level of logging, based on L<Mojo::Log>.
Spam is logged as C<info>, errors are logged as C<error>.

=back

In addition to these parameters, additional option parameters
are allowed as defined in the
L<BlogSpam API|http://blogspam.net/api>.
See L</"test_command"> method below.


=head1 HELPERS

=head2 C<blogspam>

  # In controller:
  my $bs = $c->blogspam(
    comment => 'This is a comment to test the system',
    name => 'Akron'
  );

Returns a new blogspam object, based on the given attributes.


=head1 OBJECT ATTRIBUTES

These attributes are primarily based on
the L<BlogSpam API|http://blogspam.net/api>.

=head2 C<agent>

  $bs->agent('Mozilla/5.0 (X11; Linux x86_64; rv:12.0) ...');
  my $agent = $bs->agent;

The user-agent sending the comment.
Defaults to the user-agent of the request.


=head2 C<comment>

  $bs->comment('This is just a test comment');
  my $comment_text = $bs->comment;

The comment text.


=head2 C<email>

  $bs->email('spammer@sojolicio.us');
  my $email = $bs->email;

The email address of the commenter.


=head2 C<hash>

  my $hash = $bs->hash;

Returns a hash representation of the comment.


=head2 C<ip>

  $bs->ip('192.168.0.1');
  my $ip = $bs->ip;

The ip address of the commenter.
Defaults to the ip address of the request.
Supports C<X-Forwarded-For> proxy information.


=head2 C<link>

  $bs->link('http://grimms-abenteuer.de/');
  my $link = $bs->link;

Homepage link given by the commenter.


=head2 C<name>

  $bs->name('Akron');
  my $name = $bs->name;

Name given by the commenter.


=head2 C<subject>

  $bs->subject('Fun');
  my $subject = $bs->subject;

Subject given by the commenter.


=head1 OBJECT METHODS

These methods are based on the L<BlogSpam API|http://blogspam.net/api>.

=head2 C<test_comment>

  # Blocking
  if ($bs->test_comment(
         mandatory => 'name',
         blacklist => ['192.168.0.1'])
     ) {
    print 'ham!';
  } else {
    print 'spam!';
  };

  # Non-blocking
  $bs->test_comment(
    mandatory => 'name',
    blacklist => ['192.168.0.1'],
    sub {
      my $result = shift;
      print ($result ? 'Ham!' : 'Spam!');
    }
  );

Test the comment of the blogspam object for spam or ham.
It's necessary to have a defined comment text and ip address.
The method returns nothing in case the comment is detected
as spam, C<1> if the comment is detected as ham and C<-1>
if something went horribly, horribly wrong.
Accepts additional option parameters as defined in the
L<BlogSpam API|http://blogspam.net/api>.

=over 2

=item C<blacklist>

Blacklist an IP or an array reference of IPs.
This can be either a literal IP address ("192.168.0.1")
or a CIDR range ("192.168.0.1/8").

=item C<exclude>

Exclude a plugin or an array reference of plugins from testing.
See C<get_plugins> for installed plugins of the BlogSpam instance.

=item C<fail>

Boolean flag that will, if set, return every comment as C<spam>.

=item C<mandatory>

Define an attribute (or an array reference of attributes)
of the blogspam object, that is mandatory
(e.g. "name" or "subject").

=item C<max-links>

The maximum number of links contained in the comment.
This defaults to 10.

=item C<max-size>

The maximum size of the comment text, given as a
byte expression (e.g. "2k").

=item C<min-size>

The minimum size of the comment text, given as a
byte expression (e.g. "2k").

=item C<min-words>

The minimum number of words of the comment text.
Defaults to 4.

=item C<whitelist>

Whitelist an IP or an array reference of IPs.
This can be either a literal IP address ("192.168.0.1")
or a CIDR range ("192.168.0.1/8").

=back

For a non-blocking request, append a callback function.
The parameters of the callback are identical to the methods
return values in blocking requests.


=head2 C<classify_comment>

  $bs->classify_comment('ok');
  $bs->classify_comment('ok' => sub {
    print 'Done!';
  });


Train the BlogSpam instance based on your
comment definition as C<ok> or C<spam>.
This may help to improve the spam detection.
Expects a defined C<comment> attribute and
a single parameter, either C<ok> or C<spam>.

For a non-blocking request, append a callback function.
The parameters of the callback are identical to the methods
return values in blocking requests.


=head2 C<get_plugins>

  my @plugins = $bs->get_plugins;
  $bs->get_plugins(sub {
    print join ', ', @_;
  });

Requests a list of plugins installed at the BlogSpam instance.

For a non-blocking request, append a callback function.
The parameters of the callback are identical to the methods
return values in blocking requests.

=head2 C<get_stats>

  my $stats = $bs->get_stats;
  my $stats = $bs->get_stats('http://sojolicio.us/');
  $bs->get_stats(sub {
    my $stats = shift;
  });

Requests a hash reference of statistics for your site
regarding the number of comments detected as C<ok> or C<spam>.
If no C<site> attribute is given (whether as a parameter or when
registering the plugin), this will return nothing.

For a non-blocking request, append a callback function.
The parameters of the callback are identical to the methods
return values in blocking requests.


=head1 DEPENDENCIES

L<Mojolicious>.


=head1 SEE ALSO

L<Blog::Spam::API>,
L<http://blogspam.net/>.


=head1 AVAILABILITY

  https://github.com/Akron/Mojolicious-Plugin-BlogSpam


=head1 COPYRIGHT AND LICENSE

Copyright (C) 2012, Nils Diewald.

This program is free software, you can redistribute it
and/or modify it under the same terms as Perl.

The API definition as well as the BlogSpam API code were
written and defined by Steve Kemp.

Be aware that information of your users may be send
to a third party.
This should be noted in your privacy policy if you
use a foreign BlogSpam instance.

=cut
