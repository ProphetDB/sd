package App::SD::CLI::Command::Version;

use Moo;
extends 'App::SD::CLI::Command::Help';

sub run {
    my $self = shift;
    print $self->version . "\n";
}

1;

