#!/usr/bin/env perl
use Mojolicious::Lite;

use lib '../lib';

plugin BlogSpam => {
    site => 'http://grimms-abenteuer.de/',
  log => 'test.log'
};

get '/test_comment' => sub {
  my $c = shift;
  if ($c->blogspam(
    ip => '78.94.121.107',
    name => 'Akron',
    comment => 'Ich genieße hier gerade die wunderbare Aussicht!'
  )->test_comment) {
    return $c->render_text('Fine!');
  };

  return $c->render_text('Spam!');
};

get '/get_plugins' => sub {
  my $c = shift;
  $c->render_text(join(', ', $c->blogspam->get_plugins));
};

get '/get_stats' => sub {
  my $c = shift;
  $c->render_text($c->dumper($c->blogspam->get_stats));
};

app->start;
