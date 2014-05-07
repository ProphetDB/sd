package App::SD::CLI::Command::Browser;
use Moo;

extends 'App::SD::CLI::Command::Server';

override run => sub {
    my $self = shift;
    $self->print_usage if $self->has_arg('h');

    $self->server->with_browser(1);

    Prophet::CLI->end_pager();
    print "Browser will be opened after server has been started.\n";
    $self->SUPER::run();
};

1;
