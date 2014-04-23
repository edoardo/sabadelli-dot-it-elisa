package SabadelliDotIt::Elisa::DAO::Polaroid;

use strict;
use warnings;

use Net::OAuth ();
use Net::OAuth::ProtectedResourceRequest ();
use Cache::Memcached::Fast ();
use Mojo::UserAgent;
use Time::Piece;

my $CONFIG;
my $LOGGER;
my $MEMD_CLIENT;


#
# Constructor
#

sub new {
    my $proto = shift;

    my $class = ref $proto || $proto || __PACKAGE__;

    my $self = {
        id => undef,
        data => {},
    };

    if (@_) {
        my $args = shift;

        $self->{id} = $args->{id};
        $self->{data} = $args->{data};
    }

    bless $self, $class;

    return $self;
}


#
# Accessors
#

sub id {
    my $self = shift;
    return $self->{id};
}

sub previous {
    my $self = shift;
    return $self->{data}->{previous};
}

sub title {
    my $self = shift;
    return $self->{data}->{title};
}

sub upload_date {
    my $self = shift;
    return $self->{data}->{upload_date};
}

sub media_url {
    my ($self, $format) = @_;

    # default to '-' (Medium 500) used for the main images
    $format //= 'z';

    my $photo = $self->{data}->{photo};

    return sprintf(
        'http://farm%d.staticflickr.com/%d/%d_%s_%s.jpg',
        $photo->{farm}, $photo->{server}, $photo->{id}, $photo->{secret}, $format,
    );
}


#
# Instance methods
#

# the polaroid snapped right before the current one
sub get_previous {
    my $self = shift;

    if (my $prev_id = $self->previous) {
        my $prev = $MEMD_CLIENT->get($prev_id);

        if ($prev) {
            return __PACKAGE__->new({
                id => $prev->{id},
                data => $prev->{data},
            });
        }
    }

    return;
}

sub permalink {
    my $self = shift;

    my $upload_date = gmtime($self->upload_date);
    my $seo_title = $self->_extract_seo_title($self->title);

    return join(
        '/',
        $upload_date->ymd('/'),
        $seo_title
    ); 
}


#
# Class methods
#

sub init {
    my ($class, $options) = @_;

    $CONFIG = $options->{config};

    $LOGGER = $options->{logger};

    $MEMD_CLIENT = Cache::Memcached::Fast->new({
        servers => $CONFIG->{memcached}->{servers} || [{ address => '127.0.0.1:11211' }],
        namespace => 'sabadellidotit::elisa::polaroids-',
        utf8 => 1,
    });
}

# last polaroid
sub get_last {
    my $class = shift;

    my $last = $MEMD_CLIENT->get('last');

    # update the link to the previous 
    if (not $last or ($last && not $last->{data}->{previous})) {
        $LOGGER->debug('Search link to previous for last polaroid');

        my @polaroids = $class->search({limit => 2});

        if (@polaroids) {
            $last = pop @polaroids;

            $MEMD_CLIENT->set('last', $last);
        }
    }

    if ($last) {
        return $class->new({
            id => $last->{id},
            data => $last->{data},
        });
    }

    return;
}

sub get {
    my ($class, $id) = @_;

    my $polaroid = $MEMD_CLIENT->get($id);

    # update the link to the previous 
    if ($polaroid && not $polaroid->{data}->{previous}) {
        $LOGGER->debug('Search the link to the previous polaroid');

        $class->search_before_date($polaroid->{data}->{upload_date});

        # reload requested polaroid from memcache
        # in most cases there should be the reference
        # to the previous one at this point
        # (except in case this is the oldest)
        $polaroid = $MEMD_CLIENT->get($id);
    }

    # TODO
    # handle the case where there's nothing in memcache

    if ($polaroid) {
        return $class->new({
            id => $polaroid->{id},
            data => $polaroid->{data},
        });
    }

    return;
}

# refresh cache based on last update time
sub refresh_cache {
    my $class = shift;

    if (my $last_refresh = $MEMD_CLIENT->get('last_refresh')) {
        if ((time - $last_refresh) < $CONFIG->{memcached}->{refresh_ttl}) {
            return;
        }
    }

    $LOGGER->debug('Refresh cache');

    my @polaroids = $class->search();

    if (@polaroids) {
        $MEMD_CLIENT->set('last', pop @polaroids);

        $MEMD_CLIENT->set('last_refresh', time);
    }
}

# all polaroids
sub search {
    my ($class, $filters) = @_;

    my $request_url = 'http://api.flickr.com/services/rest';

    my %request_params = (
        method => 'flickr.people.getPhotos',
        format => 'json',
        nojsoncallback => 1,
        user_id => 'me',
        page => 1,
        per_page => $filters->{limit} || 5,
        extras => 'date_upload,url_q',
    );

    if ($filters->{max_upload_date}) {
        $request_params{max_upload_date} = $filters->{max_upload_date};
    }

    my $signed_request_params = $class->_sign_flickr_request({
        request_url => $request_url,     
        request_method => 'GET',

        %request_params,
    });

    $LOGGER->info('Fire up request to Flickr');

    my $ua = Mojo::UserAgent->new();

    my $json_res = $ua->get($request_url, form => $signed_request_params)->res->json;

    # 500 error in case of failure in API call
    unless ($json_res && $json_res->{stat} eq 'ok') {
        $LOGGER->error('Flickr response not ok');

        # TODO exception handling
    }

    my @polaroids = ();

    my $photos = $json_res->{photos}->{photo};

    if (ref $photos eq 'ARRAY' && scalar @$photos) {
        my $prev_id = undef;
        my $polaroid = {};

        # sorting is newest to oldest
        # so iterate from the oldest to get the reference to the previous
        while (my $photo = pop (@$photos)) {
            $polaroid = {
                id => $photo->{id},
                data => {
                    title => $photo->{title},
                    photo => {
                        farm => $photo->{farm},
                        server => $photo->{server},
                        id => $photo->{id},
                        secret => $photo->{secret},
                    },
                    upload_date => $photo->{dateupload},
                    previous => $prev_id,
                }
            };

            my $memcached_id = $class->_build_memcached_id_from_data($polaroid);

            # use set instead of add so that the info about the previous
            # polaroid is stored on the former last polaroid
            $MEMD_CLIENT->set($memcached_id, $polaroid);

            $prev_id = $memcached_id;

            push @polaroids, $polaroid;
        }
    }

    return @polaroids;
}


# before date
sub search_before_date {
    my ($class, $epoch) = @_;

    return $class->search({max_upload_date => $epoch});
}


#
# Private methods
#

sub _build_memcached_id_from_data {
    my ($class, $photo) = @_;

    my $seo_title = $class->_extract_seo_title($photo->{data}->{title});

    my $upload_date = gmtime($photo->{data}->{upload_date});
    
    return $upload_date->ymd('') . ':' . $seo_title;
}

sub _extract_seo_title {
    my ($class, $title) = @_;

    $title = lc($title);
    $title =~ s{\s+}{-}g;
    $title =~ s{[^\w\-]}{}g;

    return $title;
}

sub _sign_flickr_request {
    my ($class, $params) = @_;

    my $request_url = delete($params->{request_url});
    my $request_method = delete($params->{request_method});

    my $request = Net::OAuth::ProtectedResourceRequest->new(
        # OAuth stuff
        consumer_key => $CONFIG->{flickr}->{key},
        consumer_secret => $CONFIG->{flickr}->{secret},
        token => $CONFIG->{flickr}->{access_token},
        token_secret => $CONFIG->{flickr}->{access_secret},
        timestamp => time,
        nonce => int(rand(2 ** 32)),
        signature_method => 'HMAC-SHA1',
        protocol_version => Net::OAuth::PROTOCOL_VERSION_1_0,
        request_method => $request_method,
        request_url => URI->new($request_url),
        extra_params => $params,
    );

    $request->sign();

    return $request->to_hash;
}

1;
