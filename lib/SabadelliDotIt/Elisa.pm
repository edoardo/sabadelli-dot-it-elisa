package SabadelliDotIt::Elisa;

# - http://www.sabadelli.it/elisa

use Mojo::Base 'Mojolicious';

use SabadelliDotIt::Elisa::DAO::Polaroid;

# This method will run once at server start
sub startup {
    my $self = shift;

    my $r = $self->routes;

    my $elisa_route = $r->under('/elisa')
        ->to(cb => sub {
            my $self = shift;

            # take the language based on the users' browser preference
            my $lang = $self->stash->{i18n}->languages();

            # check if a language is forced (via links)
            my $lang_par = $self->param('lang');

            if ($lang_par && $lang_par =~ m{^(en|it|no)$}) {
                $self->session(lang => $lang_par);
            }

            if (my $lang_session = $self->session('lang')) {
                $lang = $lang_session;

                # set the language in the session as the current one to use
                # for localizing the content
                $self->stash->{i18n}->languages($lang);
            }

            # needed in the templates for setting the lang attribute
            # and for generating the correct links for switching language
            $self->stash->{app}->{lang} = $lang;

            return 1;
        });

    # /elisa
    $elisa_route->route('/')
        ->via('GET')
        ->to('polaroids#index');

    # /elisa/2014/04/14/seo-title
    $elisa_route->route('/:year/:month/:day/(*seo)', year => qr/\d{4}/, month => qr/\d{2}/, day => qr/\d{2}/)
        ->via('GET')
        ->to('polaroids#show_polaroid');

    # /elisa/feed
    $elisa_route->route('/feed')
        ->via('GET')
        ->to('polaroids#feed');

    # defaults
    $self->defaults(app => {
        mode => $self->mode
    });

    # plugins
    $self->plugin('charset' => {charset => 'utf-8'});
    $self->plugin('I18N' => {namespace => 'SabadelliDotIt::Elisa::I18N'});
    my $config = $self->plugin('JSONConfig', {file => 'site.json'});

    # secrets
    $self->secrets([$config->{secret}]);

    # init DAO (pass some config)
    SabadelliDotIt::Elisa::DAO::Polaroid->init({
        config => {
            memcached => $config->{memcached},
            flickr => $config->{flickr},
        },
        logger => $self->app->log,
    });
}

1;
