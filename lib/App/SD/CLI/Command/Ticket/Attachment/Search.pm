package App::SD::CLI::Command::Ticket::Attachment::Search;
use Moo;
extends 'Prophet::CLI::Command::Search';
with 'Prophet::CLI::RecordCommand';
with 'App::SD::CLI::Model::Attachment';

sub type {'attachment'}

sub get_search_callback {
    my $self = shift;
    return sub {
        shift->prop('ticket') eq $self->uuid ? 1 : 0;
      }
}

1;

