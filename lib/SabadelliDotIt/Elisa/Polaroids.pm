package SabadelliDotIt::Elisa::Polaroids;

use Mojo::Base 'Mojolicious::Controller';

use SabadelliDotIt::Elisa::DAO::Polaroid;

my $dao_polaroid = 'SabadelliDotIt::Elisa::DAO::Polaroid';

# welcome page
# /elisa
sub index {
    my $self = shift;

    my $last_polaroid = $dao_polaroid->get_last();

    $self->app->log->info(
        sprintf('Rendering last polaroid: id: %s - title: %s',
            $last_polaroid->id,
            $last_polaroid->title
        )
    );

    $self->stash(
        template => 'index',
        nav => {
            prev => ($last_polaroid and $last_polaroid->permalink()),
        },
    );

    $self->render();

    # refresh the cache after refresh ttl expired
    # thus allowing getting new polaroids without hitting
    # Flickr every time
    $dao_polaroid->refresh_cache();
}

sub show_polaroid {
    my $self = shift;

    my $id = $self->stash('year') .
        $self->stash('month') .
        $self->stash('day') .
        ':' .
        $self->stash('seo');

    my $polaroid = $dao_polaroid->get($id);

    if ($polaroid and $polaroid->id) {
        $self->app->log->info(
            sprintf('Rendering polaroid: id: %s - title: %s',
                $polaroid->id,
                $polaroid->title
            )
        );

        my $prev_polaroid = $polaroid->get_previous();

        $self->stash(
            template => 'polaroid',
            polaroid => $polaroid,
            nav => {
                prev => ($prev_polaroid and $prev_polaroid->permalink()),
            },
        );
    }
    else {
        $self->render_not_found(); # XXX
    }
}

sub feed {
    my $self = shift;

    my $last_polaroid = $dao_polaroid->get_last();

    my @polaroids = ($last_polaroid);
    my $i = 9;

    # get last 10 polaroids
    while ($i--) {
        my $prev_polaroid = $last_polaroid->get_previous();

        unless ($prev_polaroid && $prev_polaroid->id) {
            last;
        }

        push @polaroids, $prev_polaroid;

        $last_polaroid = $prev_polaroid;
    }

    $self->stash(
        template => 'feed',
        polaroids => \@polaroids,
        feed => {
            last_update => $polaroids[0]->upload_date
        },
    );

    $self->render(format => 'atom');
}

1;
