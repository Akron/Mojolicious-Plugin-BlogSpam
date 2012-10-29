#!/usr/bin/env perl
use Test::Mojo;
use Test::More tests => 21;
use Mojolicious::Lite;
$|++;
use lib '../lib';

my $t = Test::Mojo->new;

my $app = $t->app;

$app->mode('production');

$app->plugin('BlogSpam' => {
  site => 'http://grimms-abenteuer.de/',
  exclude => 'badip',
  mandatory => [qw/subject name/]
});

my $bs;
ok($bs = $app->blogspam(
  comment => 'This is a test post',
  ip => '192.168.0.20',
  email => 'akron@sojolicio.us',
  link => 'http://sojolicio.us',
  name => 'Akron',
  subject => 'Test-Post',
  agent => 'mOJO-bOt'
), 'Blogspam');

is_deeply($bs->hash, {
  'email' => 'akron@sojolicio.us',
  'link' => 'http://sojolicio.us',
  'comment' => 'This is a test post',
  'subject' => 'Test-Post',
  'ip' => '192.168.0.20',
  'name' => 'Akron',
  'agent' => 'mOJO-bOt'
}, 'hash'
);

is($bs->email, 'akron@sojolicio.us', 'email');
is($bs->link, 'http://sojolicio.us', 'link');
is($bs->comment, 'This is a test post', 'comment');
is($bs->subject, 'Test-Post', 'subject');
is($bs->ip, '192.168.0.20', 'ip');
is($bs->name, 'Akron', 'name');
is($bs->agent, 'mOJO-bOt', 'agent');

my $c = Mojolicious::Controller->new;

$c->app($app);

ok($bs = $app->blogspam(
  comment => 'This is a test post',
  email => 'akron@sojolicio.us',
  link => 'http://sojolicio.us',
  name => 'Akron',
  subject => 'Test-Post'
), 'Blogspam');

ok(!$bs->ip, 'No ip');
ok(!$bs->agent, 'No agent');

my $header = $c->req->headers;
$header->host('192.168.0.1:1234');
$header->user_agent('New client');

ok($bs = $c->blogspam(
  comment => 'This is a test post'
), 'Blogspam');

is($bs->ip, '192.168.0.1', 'IP');
is($bs->agent, 'New client', 'Agent');

$header->add('X-Forwarded-For' => '192.168.0.2, 192.168.0.3');

ok($bs = $c->blogspam(
  comment => 'This is a test post'
), 'Blogspam');

is($bs->ip, '192.168.0.2', 'X-Forwarded-For');

my $opt = $bs->_options(mandatory => 'email');
like($opt, qr/exclude=badip/,     'Option String 1');
like($opt, qr/mandatory=subject/, 'Option String 2');
like($opt, qr/mandatory=name/,    'Option String 3');
like($opt, qr/mandatory=email/,   'Option String 4');

__END__

ok($bs->get_plugins > 3, 'get_plugins');
ok($bs->test_comment, 'test_comment');
ok($bs->classify_comment('ok'), 'classify_comment');
ok($bs->get_stats('http://grimms-abenteuer.de/'), 'get_stats');
