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
# ------------------------------------------------------------
# Récupère les images du catalogue
# ------------------------------------------------------------
sub getCatalogImages {
    my $arguments_count = scalar(@_);
    if ($arguments_count != 2) {
        print "ERROR :: Incorrect number of arguments passed to getCatalogImages()\n";
        return;
    }

    my $fqdn_hostname = $_[0];
    my $token         = $_[1];

    my $url = "https://$fqdn_hostname:$NB_PORT/netbackup/catalog/images";

    my $catalog_req = HTTP::Request->new(GET => $url);
    $catalog_req->header('Authorization' => $token);
    $catalog_req->header('content-type' => "$CONTENT_TYPE_V1");

    my $ua = LWP::UserAgent->new(
        timeout => 500,
        ssl_opts => {
            verify_hostname => 0,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE
        },
    );

    print "Performing Get Catalog Images Request on $url\n";
    my $response = $ua->request($catalog_req);

    if ($response->is_success) {
        print "Successfully completed Get Catalog Images Request.\n";
        my $data = decode_json($response->content);
        my $pretty = JSON->new->pretty->encode($data);
        return $pretty;
    } else {
        print "ERROR :: Get Catalog Images Request Failed!\n";
        print "HTTP GET error code: ", $response->code, "\n";
        print "HTTP GET error message: ", $response->message, "\n";
    }
}
# ------------------------------------------------------------
# Récupère la liste des jobs au format JSON
# ------------------------------------------------------------
sub getJobs {
    my $arguments_count = scalar(@_);
    if ($arguments_count != 2) {
        print "ERROR :: Incorrect number of arguments passed to getJobs()\n";
        return;
    }

    my $fqdn_hostname = $_[0];
    my $token         = $_[1];

    my $url = "https://$fqdn_hostname:$NB_PORT/netbackup/admin/jobs";

    my $jobs_req = HTTP::Request->new(GET => $url);
    $jobs_req->header('Authorization' => $token);
    $jobs_req->header('content-type' => "$CONTENT_TYPE_V1");

    my $ua = LWP::UserAgent->new(
        timeout => 500,
        ssl_opts => {
            verify_hostname => 0,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE
        },
    );

    print "Performing Get Jobs Request on $url\n";
    my $response = $ua->request($jobs_req);

    if ($response->is_success) {
        print "Successfully completed Get Jobs Request.\n";
        my $data = decode_json($response->content);
        my $pretty = JSON->new->pretty->encode($data);
        return $pretty;
    } else {
        print "ERROR :: Get Jobs Request Failed!\n";
        print "HTTP GET error code: ", $response->code, "\n";
        print "HTTP GET error message: ", $response->message, "\n";
    }
}
# ------------------------------------------------------------
# Invalide le token et ferme la session
# ------------------------------------------------------------
sub logout {
    my $arguments_count = scalar(@_);
    if ($arguments_count != 2) {
        print "ERROR :: Incorrect number of arguments passed to logout()\n";
        return;
    }

    my $fqdn_hostname = $_[0];
    my $token         = $_[1];

    my $logout_url = "https://$fqdn_hostname:$NB_PORT/netbackup/logout";

    my $logout_req = HTTP::Request->new(POST => $logout_url);
    $logout_req->header('Authorization' => $token);

    my $ua = LWP::UserAgent->new(
        timeout => 500,
        ssl_opts => {
            verify_hostname => 0,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE
        },
    );

    print "\n\nPerforming Logout Request on $logout_url\n";
    my $resp = $ua->request($logout_req);

    if ($resp->is_success) {
        print "Successfully completed Logout Request.\n";
    } else {
        print "ERROR :: Logout Request Failed!\n";
        print "HTTP POST error code: ", $resp->code, "\n";
        print "HTTP POST error message: ", $resp->message, "\n";
    }
}
