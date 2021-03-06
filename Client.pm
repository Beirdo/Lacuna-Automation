package Client;

use strict;

use Carp;
use File::Path;
use File::Spec;
use JSON::XS;
use LWP::UserAgent;
use Scalar::Util qw(blessed);
use Time::Local;

sub new {
  my $base = shift;
  die "Cannot make a new Client from ".ref($base)."\n"
    if blessed($base) && !$base->isa("Client");
  my $class = ref($base) || $base;
  my $self = ref($base) ? { %$base, @_ } : { @_ };
  bless($self, $class);
  $self->read_config();
  $self->{ua} ||= LWP::UserAgent->new();
  return $self;
}

sub read_json {
  my $self = shift;
  my $filename = shift;
  my $filetype = shift;

  my $file;
# warn "filename: $filename\n";
  unless (open($file, "<", $filename)) {
    croak "Could not read $filetype file $filename: $!" if $filetype;
    return;
  }
  my $json = join('', (<$file>));
  close($file);
  my $result = decode_json($json);
  return $result;
}

sub write_json {
  my $self = shift;
  my $filename = shift;
  my $filetype = shift;
  my $value = shift;

  my $dir = File::Spec->catpath((File::Spec->splitpath($filename))[0..1]);
  -d $dir or mkpath($dir) or croak "Could not make path $dir: $!";

  my $file;
  open($file, ">", "$filename.$$") or croak "Could not write $filetype file $filename.$$: $!";
  print $file encode_json($value);
  close $file;
  rename("$filename.$$", $filename) or croak "Could not rename $filetype file $filename.$$ to $filename: $!";
}

sub read_config {
  my $self = shift;
  croak "config not specified for Client" unless $self->{config};
  my $config = $self->read_json($self->{config}, "config");
  for my $key (qw(empire_name empire_password uri api_key)) {
    $self->{$key} = $config->{$key} if exists($config->{$key});
#    warn "$key: $self->{$key}\n";
  }
}

sub parse_time {
  my $str = shift;
  return timegm($6,$5,$4,$1,$2 - 1,$3) if $str =~ /^(\d+) (\d+) (20\d\d) (\d+):(\d+):(\d+) \+0000$/;
  return;
}

sub format_time {
  my $time = shift;

  my @elems = reverse((localtime($time))[0..5]);
  $elems[0] += 1900;
  $elems[1]++;
  sprintf("%4d-%02d-%02d %02d:%02d:%02d", @elems);
}

sub log_call {
  my $api = shift;
  my $message = shift;
  my $response = shift;
  our $time;
  our $count;

  my $now = time();
  if ($time ne $now) {
    $time = $now;
    $count = 0;
  } else {
    $count++;
  }

  my $dir = "log/".substr(format_time($time), 0, 10);
  -d $dir or mkpath($dir) or croak "Could not make path $dir: $!";

  eval { confess("stacktrace") };
  my $stack = $@;

  my $password;
  if ($api eq "/empire" && $message->{method} eq "login") {
    my $password = $message->{params}[1];
    $message->{params}[1] = "password elided";
    my $pattern = $password;
    $pattern =~ s/(\W)/\\$1/g;
    $stack =~ s/$pattern/password elided/g;
  }

  my $filename = join(".", format_time($time), sprintf("%03d", $count), $api, $message->{method});
  $filename =~ s-/--g;
  $filename =~ s- -_-g;
  my $file;
  open($file, ">", "$dir/$filename") or croak "Could not log call: $!";
  print $file encode_json({
    api => $api,
    message => $message,
    status => $response->status_line,
    response => $response->content,
    stack => $stack,
  });
  close($file);

  if ($api eq "empire" && $message->{method} eq "login") {
    $message->{params}[1] = $password;
  }
}

sub call {
  my $self = shift;
  my $api = shift;
  my $method = shift;
  my @params = @_;

  unshift(@params, $self->session_id) unless "$api/$method" eq "empire/login";

  $api = "/$api" unless $api =~ /^\//;
  my $message = { jsonrpc => "2.0", id => 1, method => $method, params => [ @params ] };
  # warn "Posting to ".($self->{uri} . $api)."\n";
  # warn "Content: ".encode_json($message)."\n";
  my $response = $self->{ua}->post($self->{uri} . $api, Content => encode_json($message));
  log_call($api, $message, $response);
  my $result = decode_json($response->content);
  croak join(": ", $result->{error}{code}, $result->{error}{message},
             JSON::XS->new->allow_nonref->canonical->pretty->encode($result->{error}{data}))
    if $result->{error};
  croak "Call failed: ".($response->status_line) unless $response->is_success;
  croak "Call response without result" unless $result->{result};
  $self->{session_id} = $result->{result}{session_id} if $result->{result}{session_id};
  $self->{session_time} = time();
  $self->write_session if $self->{session_id};
  my $time = parse_time($result->{result}{status}{server}{time});
  $result->{result}{status}{_time} = $time;
  my $empire = $result->{result}{status}{empire};
  if ($empire) {
    $empire->{_time} = $time;
    $self->write_json("cache/empire/$self->{empire_name}/status", empire_status => $empire);
  }
  my $body = $result->{result}{status}{body};
  if ($body) {
    $body->{_time} = $time;
    my @arrivals;
    if ($body->{incoming_foreign_ships}) {
      @arrivals = map { parse_time($_->{date_arrives}) } @{$body->{incoming_foreign_ships}};
    }
    $result->{_invalid} = List::Util::min(time() + 3600, @arrivals);
    $self->write_json("cache/body/$body->{id}/status", body_status => $body);
  }
  return $result->{result};
}


sub read_session {
  my $self = shift;

  my $file;
  open($file, "<", "cache/session_id") or return;
  $self->{session_id} = <$file>;
  $self->{session_time} = (stat $file)[9];
  close($file);
  chomp($self->{session_id});
}

sub write_session {
  my $self = shift;

  my $dir = "cache";
  -d $dir or mkpath($dir) or croak "Could not make path $dir: $!";

  my $file;
  open($file, ">", "cache/session_id") or die "Couldn't write cache/session_id: $!";
  print $file "$self->{session_id}\n";
  close($file);
}

sub session_id {
  my $self = shift;

# warn "Known session: $self->{session_id}\n";
  return $self->{session_id} if $self->{session_time} >= time() - 3600 * 1.5;
  $self->read_session();
# warn "Preexisting session: $self->{session_id}\n";
  return $self->{session_id} if $self->{session_time} >= time() - 3600 * 1.5;
  my $result = $self->call(empire => login => $self->{empire_name}, $self->{empire_password}, $self->{api_key});
# warn "Created session: $self->{session_id}\n";
  return $self->{session_id} if $self->{session_time} >= time() - 3600 * 1.5;
  croak "Couldn't get session_id";
}

sub empire_status {
  my $self = shift;

  my $result = $self->read_json("cache/empire/$self->{empire_name}/status");
  return $result if $result->{_time} >= time() - 610;
  my $result = $self->call(empire => login => $self->{empire_name}, $self->{empire_password}, $self->{api_key});
  return $result->{status}{empire} if $result->{status}{empire};
  croak "Couldn't get empire status";
}

sub body_status {
  my $self = shift;
  my $body_id = shift;

  my $result = $self->read_json("cache/body/$body_id/status");
  return $result if $result->{_time} >= time() - 500 && $result->{_invalid} > time();
  my $result = $self->body_buildings($body_id);
  return $result->{status}{body} if $result->{status}{body};
  croak "Couldn't get body status";
}

sub body_buildings {
  my $self = shift;
  my $body_id = shift;

  my $result = $self->read_json("cache/body/$body_id/buildings");
  return $result if $result->{_invalid} > time();
  my $result = $self->call(body => get_buildings => $body_id);
  my @completions;
  for my $building (values(%{$result->{buildings}})) {
    push(@completions, parse_time($building->{pending_build}{end})) if $building->{pending_build};
    push(@completions, parse_time($building->{work         }{end})) if $building->{work};
  }
  $result->{_invalid} = List::Util::min(time() + 3600, @completions);
  $self->write_json("cache/body/$body_id/buildings", buildings => $result);
  return $result;
}

sub body_buildable {
  my $self = shift;
  my $body_id = shift;

  my $result = $self->read_json("cache/body/$body_id/buildable");
  return $result if $result->{_invalid} > time();
  my $result = $self->call(body => get_buildable => $body_id);
  my $buildings = $self->body_buildings($body_id);
  my @completions;
  for my $building (values(%{$buildings->{buildings}})) {
    next unless $building->{pending_build};
    # next unless $building->{name} =~ /Oversight|Ore Refinery|Intelligence|University/;
    push(@completions, parse_time($building->{pending_build}{end}));
  }
  my $body = $self->body_status($body_id);
  if ($body->{incoming_foreign_ships}) {
    push(@completions, map { parse_time($_->{date_arrives}) } @{$body->{incoming_foreign_ships}});
  }
  $result->{_invalid} = List::Util::max(time() + 30, List::Util::min(time() + 600, @completions));
  $self->write_json("cache/body/$body_id/buildable", buildable => $result);
  return $result;
}

sub body_build {
  my $self = shift;
  my $body_id = shift;
  my $building_name = shift;

  my $url = "";
  my %plots;
  my $existing = $self->body_buildings($body_id);
  for my $building (values %{$existing->{buildings}}) {
    $plots{$building->{x},$building->{y}} = 1;
    $url = $building->{url} if $building->{name} eq $building_name;
  }
  my @plots;
  for my $x (-5..5) {
    for my $y (-5..5) {
      push(@plots, [ $x, $y ]) unless $plots{$x,$y};
    }
  }
  my $place = $plots[int(rand(@plots))];

  $url ||= $self->body_buildable($body_id)->{buildable}{$building_name}{url};

  return $self->building_build($url, $body_id, @$place);
}

sub building_build {
  my $self = shift;
  my $url = shift;
  my $body_id = shift;
  my $x = shift;
  my $y = shift;

  unlink("cache/body/$body_id/buildable");
  my $result = $self->call($url => build => $body_id, $x, $y);
  unlink("cache/body/$body_id/buildings") if $result;
  return $result;
}

sub building_upgrade {
  my $self = shift;
  my $url = shift;
  my $building_id = shift;

  unlink("cache/building/$building_id/view");
  my $result = $self->call($url => upgrade => $building_id);
  unlink("cache/body/$result->{status}{body}{id}/buildings") if $result;
  unlink("cache/body/$result->{status}{body}{id}/buildable") if $result && $url =~ /oversight|orerefinery|intelligence|university/;
  return $result;
}

sub building_repair {
  my $self = shift;
  my $url = shift;
  my $building_id = shift;

  my $result = $self->call($url => repair => $building_id);
  unlink("cache/body/$result->{status}{body}{id}/buildings") if $result;
  unlink("cache/building/$building_id/view") if $result;
  return $result;
}

sub building_view {
  my $self = shift;
  my $url = shift;
  my $building_id = shift;

  my $result = $self->read_json("cache/building/$building_id/view");
  return $result if $result->{_invalid} > time();
  my $result = $self->call($url, view => $building_id);
  my @completions;
  for my $building ($result->{building}) {
    push(@completions, parse_time($building->{pending_build}{end})) if $building->{pending_build};
    push(@completions, parse_time($building->{work         }{end})) if $building->{work};
  }
  push(@completions, time() + 300) unless $result->{building}{upgrade}{can};
  $result->{_invalid} = List::Util::min(time() + 3600, @completions);
  $self->write_json("cache/building/$building_id/view", building_view => $result);
  return $result;
}

sub building_stats_for_level {
  my $self = shift;
  my $url = shift;
  my $building_id = shift;
  my $level = shift;

  my $result = $self->read_json("cache/building/$building_id/stats_$level");
  return $result if $result;
  my $result = $self->call($url, get_stats_for_level => $building_id, $level);
  $self->write_json("cache/building/$building_id/stats_$level", building_stats => $result);
  return $result;
}

sub park_party {
  my $self = shift;
  my $building_id = shift;

  my $result = $self->call(park => throw_a_party => $building_id);
  unlink("cache/body/$result->{status}{body}{id}/buildings") if $result;
  unlink("cache/building/$building_id/view") if $result;
  return $result;
}

sub recycle_recycle {
  my $self = shift;
  my $building_id = shift;
  my $water = shift;
  my $ore = shift;
  my $energy = shift;

  my $result = $self->call(wasterecycling => recycle => $building_id, $water, $ore, $energy, 0);
  unlink("cache/body/$result->{status}{body}{id}/buildings") if $result;
  unlink("cache/building/$building_id/view") if $result;
  return $result;
}

sub archaeology_search {
  my $self = shift;
  my $building_id = shift;
  my $ore = shift;

  my $result = $self->call(archaeology => search_for_glyph => $building_id, $ore);
  unlink("cache/body/$result->{status}{body}{id}/buildings") if $result;
  unlink("cache/building/$building_id/view") if $result;
  return $result;
}

sub port_all_ships {
  my $self = shift;
  my $building_id = shift;

  my $result = $self->read_json("cache/building/$building_id/view_all_ships");
  return $result if $result->{_invalid} > time();
  my $page = 1;
  my @ships;
  my $result;
  for (;;) {
    $result = $self->call(spaceport => view_all_ships => $building_id, $page);
    push(@ships, @{$result->{ships}});
    last if @{$result->{ships}} < 25;
    $page++;
  }
  $result->{ships} = [ @ships ];
  my @completions;
  for my $ship (@{$result->{ships}}) {
    if ($ship->{date_available}) {
      my $available = parse_time($ship->{date_available});
      push(@completions, $available) if $available > time() + 30;
    }
    push(@completions, parse_time($ship->{date_arrives})) if $ship->{date_arrives};
  }
  $result->{_invalid} = List::Util::min(time() + 3600, @completions);
  $self->write_json("cache/building/$building_id/view_all_ships", spaceport_view_all_ships => $result);
  return $result;
}

sub trade_push {
  my $self = shift;
  my $building_id = shift;
  my $target_id = shift;
  my $items = shift;
  my $options = shift;

  my $result = $self->call(trade => push_items => $building_id, $target_id, $items, $options);
  if ($result) {
    unlink("cache/body/$target_id/status");
    for my $body ($target_id, $result->{status}{body}{id}) {
      my $buildings = $self->body_buildings($body);
      for my $id (keys %{$buildings->{buildings}}) {
        unlink("cache/building/$id/view_all_ships");
      }
    }
  }
  return $result;
}

1;
