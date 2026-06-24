#!/usr/bin/env perl
package netbackup;

use JSON;
use warnings;
use Text::Table;
use LWP::UserAgent;
use LWP::Protocol::https;

# Désactivation de la vérification SSL (à adapter en production)
$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;

# Types de contenu pour l'API NetBackup
$CONTENT_TYPE_V1 = "application/vnd.netbackup+json; version=1.0";
$CONTENT_TYPE_V2 = "application/vnd.netbackup+json; version=2.0";
$NB_PORT = 1556;

# ------------------------------------------------------------
# Fonction de login – retourne un token valide 24h
# ------------------------------------------------------------
sub login {
    my $arguments_count = scalar(@_);
    if ($arguments_count != 3 && $arguments_count != 5) {
        print "ERROR :: Incorrect number of arguments passed to login()\n";
        return;
    }

    my $fqdn_hostname = $_[0];
    my $username      = $_[1];
    my $password      = $_[2];
    my $domainname;
    my $domaintype;

    if ($arguments_count == 5) {
        $domainname = $_[3];
        $domaintype = $_[4];
    }

    my $token_url = "https://$fqdn_hostname:$NB_PORT/netbackup/login";

    my $post_data = '{ "userName": "'.$username.'", "password": "'.$password.'" }';
    if ($arguments_count == 5) {
        $post_data = '{ "userName": "'.$username.'", "password": "'.$password.'", "domainName": "'.$domainname.'", "domainType": "'.$domaintype.'" }';
    }

    my $req = HTTP::Request->new(POST => $token_url);
    $req->header('content-type' => "$CONTENT_TYPE_V1");
    $req->content($post_data);

    my $ua = LWP::UserAgent->new(
        timeout => 500,
        ssl_opts => {
            verify_hostname => 0,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE
        },
    );

    print "Performing Login Request on $token_url\n";
    my $resp = $ua->request($req);

    if ($resp->is_success) {
        my $message = decode_json($resp->content);
        my $token = $message->{"token"};
        print "Successfully completed Login Request.\n\n";
        return $token;
    } else {
        print "ERROR :: Login Request Failed!\n";
        print "HTTP POST error code: ", $resp->code, "\n";
        print "HTTP POST error message: ", $resp->message, "\n";
    }
}
