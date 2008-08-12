package App::SD::CLI::Command::Ticket::Details;
use Moose;
extends 'App::SD::CLI::Command::Ticket::Show';

override run => sub {
    my $self = shift;
    my $record = $self->_load_record;

    print "\n=head1 METADATA\n\n";
    super();

    print "\n=head1 ATTACHMENTS\n\n";
    my $attachments = App::SD::Collection::Attachment->new(
        handle => $self->app_handle->handle,
    );
    $attachments->matching(sub {
        shift->prop('ticket') eq $self->uuid ? 1 : 0;
    });
    print $_->format_summary . "\n" for $attachments->items;

    print "\n=head1 COMMENTS\n\n";
    my $comments = App::SD::Collection::Comment->new(
        handle => $self->app_handle->handle,
    );
    $comments->matching(sub {
        shift->prop('ticket') eq $self->uuid ? 1 : 0;
    });
    print $_->prop('content') . "\n" for $comments->items;
};

__PACKAGE__->meta->make_immutable;
no Moose;

1;

