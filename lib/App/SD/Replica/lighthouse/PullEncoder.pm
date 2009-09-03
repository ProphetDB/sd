package App::SD::Replica::lighthouse::PullEncoder;
use Any::Moose;
extends 'App::SD::ForeignReplica::PullEncoder';

use Params::Validate qw(:all);
use Memoize;
use Time::Progress;
use DateTime;

has sync_source => (
    isa => 'App::SD::Replica::lighthouse',
    is  => 'rw',
);

my %PROP_MAP = %App::SD::Replica::lighthouse::PROP_MAP;

sub ticket_id {
    my $self   = shift;
    return shift->number;
}

=head2 translate_ticket_state

=cut

sub translate_ticket_state {
    my $self   = shift;
    my $ticket = shift;

    return $ticket;
}

=head2 find_matching_tickets QUERY

Returns a array of all tickets found matching your QUERY hash.

=cut

sub find_matching_tickets {
    my $self                   = shift;
    my %query                  = (@_);
    my $last_changeset_seen_dt = $self->_only_pull_tickets_modified_after()
      || DateTime->from_epoch( epoch => 0 );
    my @tickets = $self->sync_source->lighthouse->tickets( query => 'all' );
    my @updated = map { $_->load( $_->number ); $_ }
      grep { $_->{updated_at} ge $last_changeset_seen_dt } @tickets;
    return \@updated;
}

sub _only_pull_tickets_modified_after {
    my $self = shift;

    my $last_pull = $self->sync_source->upstream_last_modified_date();
    return unless $last_pull;
    my $before = App::SD::Util::string_to_datetime($last_pull);
    $self->log_debug( "Failed to parse '" . $self->sync_source->upstream_last_modified_date() . "' as a timestamp. That means we have to sync ALL history") unless ($before);
    return $before;
}

=head2 find_matching_transactions { ticket => $id, starting_transaction => $num  }

Returns a reference to an array of all transactions (as hashes) on ticket $id after transaction $num.

=cut

sub find_matching_transactions {
    my $self     = shift;
    my %args     = validate( @_, { ticket => 1, starting_transaction => 1 } );
    my @raw_versions = @{ $args{ticket}->versions };
    my @raw_attachments = @{ $args{ticket}->attachments|| [] };

    my @raw_txns = ( @raw_versions, @raw_attachments );
    my @txns;
    for my $txn ( @raw_txns ) {
        my $txn_date = $txn->created_at->epoch;

        # Skip things we know we've already pulled
        next if $txn_date < ( $args{'starting_transaction'} || 0 );

        # Skip things we've pushed
        next if (
            $self->sync_source->foreign_transaction_originated_locally(
                $txn_date, $args{'ticket'}->number
            )
          );

        push @txns,
          {
            timestamp => $txn->created_at,
            object    => $txn,
            serial    => $txn->created_at->epoch,
            $txn->created_at == $args{ticket}->created_at
            ? ( is_create => 1 )
            : (),
          };
    }

    $self->sync_source->log_debug('Done looking at pulled txns');
    return \@txns;
}

sub transcode_create_txn {
    my $self        = shift;
    my $txn         = shift;
    my $ticket      = $txn->{object};

    my $ticket_uuid = 
          $self->sync_source->uuid_for_remote_id($ticket->number);
    my $creator = $self->resolve_user_id_to( undef, $ticket->creator_name );
    my $created = $ticket->created_at;
    my $changeset = Prophet::ChangeSet->new(
        {
            original_source_uuid => $ticket_uuid,
            original_sequence_no => $created->epoch,
            creator              => $creator,
            created              => $created->ymd . " " . $created->hms
        }
    );

    my $change = Prophet::Change->new(
        {
            record_type => 'ticket',
            record_uuid => $ticket_uuid,
            change_type => 'add_file',
        }
    );

    for my $prop (qw/title body state /) {
        next unless $ticket->$prop;
        $change->add_prop_change(
            name => $PROP_MAP{$prop} || $prop,
            new => $ticket->$prop,
        );
    }
     
    if ( $ticket->assigned_user_id ) {
        $change->add_prop_change(
            name => 'owner',
            new  => $ticket->assigned_user_name . '('
              . $ticket->assigned_user_id . ')',
        );
    }

    if ( $ticket->milestone_id ) {
        $change->add_prop_change(
            name => 'milestone',
            new  => $ticket->milestone_title,
        );
    }

    $change->add_prop_change(
        name => $self->sync_source->uuid . '-id',
        new => $ticket->number,
    );

    $changeset->add_change( { change => $change } );
    return $changeset;
}

# we might get return:
# 0 changesets if it was a null txn
# 1 changeset if it was a normal txn
# 2 changesets if we needed to to some magic fixups.

sub transcode_one_txn {
    my $self               = shift;
    my $txn_wrapper        = shift;
    my $ticket = shift;

    my $txn = $txn_wrapper->{object};
    if ( $txn_wrapper->{is_create} ) {
        return $self->transcode_create_txn($txn_wrapper);
    }

    my $ticket_uuid =
      $self->sync_source->uuid_for_remote_id( $ticket->number );

    my $changeset;

    if ( $txn->can('filename') ) {
        $changeset = Prophet::ChangeSet->new(
            {
                original_source_uuid => $ticket_uuid,
                original_sequence_no => $txn->created_at->epoch,
                creator =>
                  $self->resolve_user_id_to( undef, $txn->uploader_id ),
                created => $txn->created_at->ymd . " " . $txn->created_at->hms
            }
        );

        # it's an attachment
        $self->_recode_attachment_create(
            ticket_uuid => $ticket_uuid,
            changeset   => $changeset,
            attachment  => $txn,
        );
    }
    else {
        $changeset = Prophet::ChangeSet->new(
            {
                original_source_uuid => $ticket_uuid,
                original_sequence_no => $txn->created_at->epoch,
                creator =>
                  $self->resolve_user_id_to( undef, $txn->creator_name ),
                created => $txn->created_at->ymd . " " . $txn->created_at->hms
            }
        );

        my $change = Prophet::Change->new(
            {
                record_type => 'ticket',
                record_uuid => $ticket_uuid,
                change_type => 'update_file'
            }
        );
        my $diffable_attrs = $txn->diffable_attributes;
        if ( keys %$diffable_attrs ) {
            my %hash = (
                ':tag'           => 'tag',
                ':milestone'     => 'milestone_id',
                ':assigned_user' => 'assigned_user_id',
                ':state'         => 'state',
            );
            for my $attr ( keys %$diffable_attrs ) {
                next unless $hash{$attr};
                my $method = $hash{$attr};

                if ( $attr eq ':milestone' ) {
                    my $old = $diffable_attrs->{$attr};
                    my $old_title;
                    if ($old) {

                        # find milestone title
                        my $milestone =
                          $self->sync_source->lighthouse->milestone;
                        $milestone->load($old);
                        $old_title = $milestone->title;
                    }
                    $change->add_prop_change(
                        name => 'milestone',
                        new  => $ticket->milestone_id
                        ? $ticket->milestone_title
                        : undef,
                        old => $old_title || $old,
                    );
                }
                elsif ( $attr eq ':assigned_user' ) {
                    my $old = $diffable_attrs->{$attr};
                    my $old_with_name;
                    if ($old) {
                        require Net::Lighthouse::User;
                        my $user = Net::Lighthouse::User->new(
                            map { $_ => $self->sync_source->lighthouse->$_ }
                              grep { $self->sync_source->lighthouse->$_ }
                              qw/account
                              email password token/
                        );
                        eval { $user->load($old) };
                        if ($@) {
                            warn "can't load user $old on lighthouse";
                        }
                        else {
                            $old_with_name =
                              $user->name . '(' . $user->id . ')';
                        }
                    }
                    $change->add_prop_change(
                        name => 'owner',
                        new  => $ticket->assigned_user_id
                        ? ( $ticket->assigned_user_name . '('
                              . $ticket->assigned_user_id
                              . ')' )
                        : undef,
                        $old_with_name ? ( old => $old_with_name ) : (),
                    );
                }
                else {

                    $change->add_prop_change(
                        name => $PROP_MAP{ $hash{$attr} } || $hash{$attr},
                        new  => $txn->$method,
                        old  => $diffable_attrs->{$attr},
                    );
                }
            }
        }

        $changeset->add_change( { change => $change } )
          if $change->has_prop_changes;

        $self->_include_change_comment( $changeset, $ticket_uuid, $txn );
    }

    return unless $changeset->has_changes;
    return $changeset;
}

sub _include_change_comment {
    my $self        = shift;
    my $changeset   = shift;
    my $ticket_uuid = shift;
    my $txn         = shift;

    my $comment = $self->new_comment_creation_change();

    if ( my $content = $txn->body ) {
        if ( $content !~ /^\s*$/s ) {
            $comment->add_prop_change(
                name => 'created',
                new  => $txn->created_at->ymd . ' ' . $txn->created_at->hms,
            );
            $comment->add_prop_change(
                name => 'creator',
                new  => $self->resolve_user_id_to( undef => $txn->creator_name ),
            );
            $comment->add_prop_change( name => 'content', new => $content );
            $comment->add_prop_change(
                name => 'content_type',
                new  => 'text/plain',
            );
            $comment->add_prop_change( name => 'ticket', new => $ticket_uuid, );
            $changeset->add_change( { change => $comment } );
        }
    }
}

sub _recode_attachment_create {
    my $self = shift;
    my %args =
      validate( @_,
        { ticket_uuid => 1, changeset => 1, attachment => 1 } );
    my $change = Prophet::Change->new(
        {
            record_type => 'attachment',
            record_uuid => $self->sync_source->uuid_for_url(
                    $self->sync_source->remote_url
                  . "/attachment/"
                  . $args{'attachment'}->id,
            ),
            change_type => 'add_file',
        }
    );

    $change->add_prop_change(
        name => 'content_type',
        old  => undef,
        new  => $args{'attachment'}->content_type,
    );

    $change->add_prop_change(
        name => 'created',
        old  => undef,
        new  => $args{attachment}->created_at->ymd . ' '
          . $args{attachment}->created_at->hms,
    );
    $change->add_prop_change(
        name => 'creator',
        old  => undef,
        new =>
          $self->resolve_user_id_to( email_address =>
              $args{'attachment'}->uploader_id )
    );

    $change->add_prop_change(
        name => 'content',
        old  => undef,
        new  => $args{'attachment'}->content,
    );
    $change->add_prop_change(
        name => 'name',
        old  => undef,
        new  => $args{'attachment'}->filename,
    );
    $change->add_prop_change(
        name => 'ticket',
        old  => undef,
        new  => $args{ticket_uuid},
    );
    $args{'changeset'}->add_change( { change => $change } );
}

sub translate_prop_status {
    my $self   = shift;
    my $status = shift;
    return lc($status);
}

sub resolve_user_id_to {
    my $self = shift;
    shift;
    my $id   = shift;
    return $id;
#    return $id . '@lighthouse';
}

__PACKAGE__->meta->make_immutable;
no Any::Moose;
1;
