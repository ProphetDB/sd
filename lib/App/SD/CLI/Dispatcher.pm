#!/usr/bin/env perl
package App::SD::CLI::Dispatcher;
use Prophet::CLI::Dispatcher -base;
use Moose;

Prophet::CLI::Dispatcher->add_command_prefix('App::SD::CLI::Command');

# "sd ?about" => "sd help about"
rewrite qr/^\?(.*)/ => sub { "help $1" };

# 'sd about' -> 'sd help about', 'sd copying' -> 'sd help copying'
rewrite [ ['about', 'copying'] ] => sub { "help $1" };

#on '' => run_command('Shell');

under help => sub {
    on intro   => run_command('Help::Intro');
    on about   => run_command('Help::About');
    on config  => run_command('Help::Config');
    on copying => run_command('Help::Copying');

    on [ ['author', 'authors'] ]         => run_command('Help::Authors');
    on [ ['environment', 'env'] ]        => run_command('Help::Environment');
    on [ ['ticket', 'tickets'] ]         => run_command('Help::Tickets');
    on [ ['attachment', 'attachments'] ] => run_command('Help::Attachments');
    on [ ['comment', 'comments'] ]       => run_command('Help:::Comments');

    on [
        ['ticket', 'attachment', 'comment'],
        ['list', 'search', 'find'],
    ] => run_command('Help::Search');

    on [ ['search', 'list', 'find'] ] => run_command('Help::Search');

    on [ ['sync', 'push', 'pull', 'publish', 'server'] ]
        => run_command('Help::Sync');
};

on help => run_command('Help');

under ticket => sub {
    on [ [ 'search', 'list', 'ls' ] ] => run_command('Ticket::Search');
    on [ [ 'new',    'create' ] ]  => run_command('Ticket::Create');
    on [ [ 'show',   'display' ] ] => run_command('Ticket::Show');
    on [ [ 'update', 'edit' ] ]    => run_command('Ticket::Update');
    on basics   => run_command('Ticket::Basics');
    on comments => run_command('Ticket::Comments');
    on comment  => run_command('Ticket::Comment');
    on details  => run_command('Ticket::Details');

    on ['give', qr/.*/, qr/.*/] => sub {
        my $self = shift;
        $self->context->set_arg(id    => $2);
        $self->context->set_arg(owner => $3);
        run('ticket update', $self, @_);
    };

    on [ ['resolve', 'close'] ] => sub {
        my $self = shift;
        $self->context->set_prop(status => 'closed');
        run('ticket update', $self, @_);
    };

    under comment => sub {
        on create => run_command('Ticket::Comment::Create');
        on update => run_command('Ticket::Comment::Update');
    };

    under attachment => sub {
        on create => run_command('Ticket::Attachment::Create');
        on search => run_command('Ticket::Attachment::Search');
    };
};

under attachment => sub {
    on content => run_command('Attachment::Content');
    on create  => run_command('Attachment::Create');
};

# allow type to be specified via primary commands, e.g.
# 'sd ticket display --id 14' -> 'sd display --type ticket --id 14'
on qr{^(ticket|comment|attachment) \s+ (.*)}xi => sub {
    my $self = shift;
    $self->context->set_arg(type => $1);
    run($2, $self, @_);
};

redispatch_to('Prophet::CLI::Dispatcher');

sub run_command {Prophet::CLI::Dispatcher::run_command(@_) }


__PACKAGE__->meta->make_immutable;
no Moose;

1;

