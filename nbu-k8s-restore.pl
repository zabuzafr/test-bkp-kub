#!/usr/bin/perl
#
# nbu-k8s-restore.pl — Restauration interactive d'un namespace Kubernetes
#                      depuis NetBackup 10.x via l'API REST.
#
# Flux : namespace source -> point de restauration -> cluster cible -> namespace cible
#
# Auth NetBackup : POST /netbackup/login renvoie un JWT que l'on place BRUT
# dans l'en-tete Authorization (pas de prefixe "Bearer").
#
use strict;
use warnings;
use utf8;

use LWP::UserAgent;
use HTTP::Request;
use JSON::PP;
use Getopt::Long;
use POSIX qw(strftime);

binmode(STDOUT, ':encoding(UTF-8)');

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

my %opt = (
    primary     => $ENV{NBU_PRIMARY}  || '',
    port        => $ENV{NBU_PORT}     || 1556,
    user        => $ENV{NBU_USER}     || '',
    pass        => $ENV{NBU_PASS}     || '',
    domain      => $ENV{NBU_DOMAIN}   || '',
    domaintype  => $ENV{NBU_DOMTYPE}  || '',
    apikey      => $ENV{NBU_APIKEY}   || '',
    insecure    => 0,
    dryrun      => 0,
    timeout     => 120,
);

GetOptions(
    'primary=s'     => \$opt{primary},
    'port=i'        => \$opt{port},
    'user=s'        => \$opt{user},
    'pass=s'        => \$opt{pass},
    'domain=s'      => \$opt{domain},
    'domain-type=s' => \$opt{domaintype},
    'apikey=s'      => \$opt{apikey},
    'insecure!'     => \$opt{insecure},
    'dry-run!'      => \$opt{dryrun},
    'timeout=i'     => \$opt{timeout},
    'help|h'        => \&usage,
) or usage();

usage("--primary est obligatoire") unless $opt{primary};
usage("Fournir soit --apikey, soit --user et --pass")
    unless $opt{apikey} || ($opt{user} && $opt{pass});

my $BASE = "https://$opt{primary}:$opt{port}/netbackup";
my $UA   = LWP::UserAgent->new(timeout => $opt{timeout});
$UA->ssl_opts(verify_hostname => 0, SSL_verify_mode => 0) if $opt{insecure};

my $JSON  = JSON::PP->new->utf8->canonical->pretty;
my $TOKEN;

# --------------------------------------------------------------------------
# Programme principal
# --------------------------------------------------------------------------

sub main {
    $TOKEN = $opt{apikey} ? $opt{apikey} : nb_login();

    # 1. Namespaces sauvegardes
    my $assets = fetch_k8s_namespace_assets();
    die "Aucun namespace Kubernetes trouve dans les assets NetBackup.\n"
        unless @$assets;

    my $src = pick(
        "Namespace source",
        $assets,
        sub {
            my $a = shift;
            sprintf('%-40s  (cluster: %s)', $a->{name}, $a->{cluster} // '?');
        }
    );

    # 2. Points de restauration
    print "\nRecherche des points de restauration pour '$src->{name}'...\n";
    my $images = fetch_recovery_points($src);
    die "Aucun point de restauration pour '$src->{name}'.\n" unless @$images;

    my $img = pick(
        "Point de restauration",
        $images,
        sub {
            my $i = shift;
            sprintf('%-24s  %s  %s',
                $i->{backup_time}, human_size($i->{size}), $i->{policy} // '');
        }
    );

    # 3. Cluster cible : les clusters connus de NetBackup, deduits des assets.
    #    Un cluster cible doit de toute facon etre enregistre dans NetBackup.
    my @clusters = uniq(grep { defined && length } map { $_->{cluster} } @$assets);
    my $cluster = pick(
        "Cluster Kubernetes cible",
        [ map { { name => $_ } } @clusters ],
        sub { $_[0]->{name} }
    );

    # 4. Namespace cible
    my $target = ask("Namespace cible", $src->{name});
    my $exists = ask_yn(
        "Le namespace '$target' existe-t-il deja sur $cluster->{name} ?", 0);
    my $proceed = 0;
    if ($exists) {
        $proceed = ask_yn(
            "Poursuivre malgre tout (restaure les ressources manquantes, "
          . "n'ecrase pas l'existant) ?", 0);
        unless ($proceed) {
            print "Abandon : le namespace existe et la poursuite est refusee.\n";
            exit 0;
        }
    }

    # Recapitulatif
    print "\n", '-' x 68, "\n";
    printf "  Source       : %s (cluster %s)\n", $src->{name}, $src->{cluster} // '?';
    printf "  Image        : %s  [%s]\n", $img->{backup_time}, $img->{id};
    printf "  Cluster cible: %s\n", $cluster->{name};
    printf "  Namespace    : %s%s\n", $target,
           ($target eq $src->{name} ? ' (identique a la source)' : ' (alternatif)');
    printf "  NS existant  : %s\n", $exists ? 'oui, poursuite autorisee' : 'non';
    print '-' x 68, "\n";

    exit 0 unless ask_yn("Lancer la restauration ?", 0);

    my $job = submit_restore($src, $img, $cluster->{name}, $target, $proceed);

    if ($opt{dryrun}) {
        print "\n[dry-run] Rien n'a ete envoye.\n";
    } else {
        print "\nRestauration soumise. Job ID : ", ($job // 'inconnu'), "\n";
        print "Suivi : $BASE/admin/jobs/$job\n" if $job;
    }

    nb_logout() unless $opt{apikey};
}

# --------------------------------------------------------------------------
# Appels NetBackup
# --------------------------------------------------------------------------

sub nb_login {
    my %body = (userName => $opt{user}, password => $opt{pass});
    $body{domainName} = $opt{domain}     if $opt{domain};
    $body{domainType} = $opt{domaintype} if $opt{domaintype};

    my $req = HTTP::Request->new(POST => "$BASE/login");
    $req->header('Content-Type' => 'application/vnd.netbackup+json; version=1.0');
    $req->content(JSON::PP->new->utf8->encode(\%body));

    my $res = $UA->request($req);
    unless ($res->is_success) {
        die "Login echoue (" . $res->code . " " . $res->message . ")\n"
          . trim_body($res->content) . "\n";
    }
    my $tok = eval { JSON::PP->new->utf8->decode($res->content)->{token} };
    die "Login : token absent de la reponse.\n" unless $tok;
    return $tok;
}

sub nb_logout {
    my $req = HTTP::Request->new(POST => "$BASE/logout");
    $req->header(Authorization => $TOKEN);
    $UA->request($req);
    return;
}

# GET paginé. NetBackup pagine via page[limit] / page[offset]
# et repond en JSON:API : { data => [ { id, attributes => {...} } ] }
sub nb_get_all {
    my ($path, %args) = @_;
    my $version = $args{version} || '3.0';
    my $limit   = $args{limit}   || 100;
    my $max     = $args{max}     || 1000;

    my (@rows, $offset);
    $offset = 0;

    while ($offset < $max) {
        my $sep = ($path =~ /\?/) ? '&' : '?';
        my $url = "$BASE$path${sep}page%5Blimit%5D=$limit&page%5Boffset%5D=$offset";

        my $req = HTTP::Request->new(GET => $url);
        $req->header(Authorization => $TOKEN);
        $req->header(Accept => "application/vnd.netbackup+json; version=$version");

        my $res = $UA->request($req);
        unless ($res->is_success) {
            die "GET $path a echoue (" . $res->code . " " . $res->message . ")\n"
              . trim_body($res->content) . "\n";
        }

        my $doc  = eval { JSON::PP->new->utf8->decode($res->content) }
            or die "Reponse JSON illisible pour $path\n";
        my $page = $doc->{data} || [];
        last unless @$page;

        push @rows, @$page;
        last if @$page < $limit;
        $offset += $limit;
    }
    return \@rows;
}

# Namespaces Kubernetes connus de NetBackup.
# Le service d'assets accepte un filtre OData sur ?filter=
sub fetch_k8s_namespace_assets {
    my $filter = "workloadType eq 'Kubernetes' and assetType eq 'namespace'";
    my $rows   = nb_get_all('/assets?filter=' . uri_escape($filter));

    my @out;
    for my $r (@$rows) {
        my $at = $r->{attributes} || {};
        # Selon la version, le nom du cluster remonte sous differentes cles.
        my $cluster = $at->{clusterName}
                   // $at->{kubernetesClusterName}
                   // $at->{commonAssetAttributes}{clusterName};
        push @out, {
            id      => $r->{id},
            name    => $at->{displayName} // $at->{name} // $r->{id},
            cluster => $cluster,
            raw     => $at,
        };
    }
    @out = sort { $a->{name} cmp $b->{name} } @out;
    return \@out;
}

# Points de restauration = images catalogue rattachees au namespace.
sub fetch_recovery_points {
    my ($src) = @_;
    my $filter = "clientName eq '$src->{name}'";
    my $rows   = nb_get_all('/catalog/images?filter=' . uri_escape($filter),
                            version => '3.0');

    my @out;
    for my $r (@$rows) {
        my $at = $r->{attributes} || {};
        push @out, {
            id          => $r->{id},
            backup_time => $at->{backupTime} // '',
            policy      => $at->{policyName},
            client      => $at->{clientName},
            size        => $at->{imageSizeKB} ? $at->{imageSizeKB} * 1024 : undef,
        };
    }
    # Plus recent en premier.
    @out = sort { ($b->{backup_time} // '') cmp ($a->{backup_time} // '') } @out;
    return \@out;
}

# ==========================================================================
# >>> A VERIFIER CONTRE LA REFERENCE API DE VOTRE VERSION <<<
#
# Le chemin et le payload de soumission d'une restauration Kubernetes ne sont
# pas documentes publiquement de facon fiable. Les valeurs ci-dessous suivent
# la convention des autres endpoints de recuperation NetBackup, mais doivent
# etre confrontees a la reference API de VOTRE primary avant usage reel.
#
# Utiliser --dry-run pour afficher le payload sans l'envoyer, puis ajuster
# $RECOVERY_PATH et la structure de %payload.
# ==========================================================================
my $RECOVERY_PATH = '/recovery/workloads/kubernetes/scenarios/namespace-recovery/start';

sub submit_restore {
    my ($src, $img, $cluster, $target, $proceed_if_exists) = @_;

    my %payload = (
        data => {
            type       => 'recoveryRequest',
            attributes => {
                recoveryPoint => {
                    backupId   => $img->{id},
                    assetId    => $src->{id},
                },
                recoveryTarget => {
                    cluster            => $cluster,
                    namespace          => $target,
                    useOriginalNamespace =>
                        ($target eq $src->{name}) ? JSON::PP::true : JSON::PP::false,
                    overwriteExistingNamespace =>
                        $proceed_if_exists ? JSON::PP::true : JSON::PP::false,
                },
            },
        },
    );

    my $json = $JSON->encode(\%payload);

    if ($opt{dryrun}) {
        print "\n[dry-run] POST $BASE$RECOVERY_PATH\n$json\n";
        return;
    }

    my $req = HTTP::Request->new(POST => "$BASE$RECOVERY_PATH");
    $req->header(Authorization  => $TOKEN);
    $req->header('Content-Type' => 'application/vnd.netbackup+json; version=3.0');
    $req->content($json);

    my $res = $UA->request($req);
    unless ($res->is_success) {
        die "Soumission refusee (" . $res->code . " " . $res->message . ")\n"
          . trim_body($res->content) . "\n"
          . "Si le code est 404, l'endpoint differe sur votre version :\n"
          . "  relancez avec --dry-run et corrigez \$RECOVERY_PATH.\n";
    }

    my $doc = eval { JSON::PP->new->utf8->decode($res->content) };
    return $doc->{data}{id}
        // $doc->{data}{attributes}{jobId}
        // $doc->{jobId};
}

# --------------------------------------------------------------------------
# Interface interactive
# --------------------------------------------------------------------------

sub pick {
    my ($title, $items, $fmt) = @_;

    print "\n$title\n", '-' x 68, "\n";
    for my $i (0 .. $#$items) {
        printf "  %3d) %s\n", $i + 1, $fmt->($items->[$i]);
    }

    while (1) {
        print "\nChoix [1-", scalar(@$items), "] (q pour quitter) : ";
        my $in = <STDIN>;
        exit 0 unless defined $in;
        chomp $in;
        exit 0 if lc($in) eq 'q';
        return $items->[$in - 1]
            if $in =~ /^\d+$/ && $in >= 1 && $in <= @$items;
        print "Saisie invalide.\n";
    }
}

sub ask {
    my ($msg, $default) = @_;
    print "\n$msg", (defined $default ? " [$default]" : ''), " : ";
    my $in = <STDIN>;
    exit 0 unless defined $in;
    chomp $in;
    return length($in) ? $in : $default;
}

sub ask_yn {
    my ($msg, $default) = @_;
    my $hint = $default ? 'O/n' : 'o/N';
    while (1) {
        print "$msg [$hint] : ";
        my $in = <STDIN>;
        exit 0 unless defined $in;
        chomp $in;
        return $default unless length $in;
        return 1 if $in =~ /^(o|oui|y|yes)$/i;
        return 0 if $in =~ /^(n|non|no)$/i;
    }
}

# --------------------------------------------------------------------------
# Utilitaires
# --------------------------------------------------------------------------

sub uri_escape {
    my ($s) = @_;
    $s =~ s/([^A-Za-z0-9\-_.~])/sprintf('%%%02X', ord($1))/ge;
    return $s;
}

sub uniq {
    my %seen;
    return grep { !$seen{$_}++ } @_;
}

sub human_size {
    my ($b) = @_;
    return '-' unless defined $b && $b > 0;
    my @u = qw(o Ko Mo Go To);
    my $i = 0;
    while ($b >= 1024 && $i < $#u) { $b /= 1024; $i++ }
    return sprintf('%.1f %s', $b, $u[$i]);
}

sub trim_body {
    my ($c) = @_;
    return '' unless defined $c;
    $c =~ s/\s+/ /g;
    return length($c) > 400 ? substr($c, 0, 400) . '...' : $c;
}

sub usage {
    my ($msg) = @_;
    print "ERREUR: $msg\n\n" if $msg && !ref $msg;
    print <<"END";
Usage: $0 --primary <serveur> [options]

Authentification (au choix) :
  --apikey <cle>          Cle API NetBackup (recommande : pas d'expiration courte)
  --user <u> --pass <p>   Identifiants ; --domain et --domain-type si AD/LDAP

Options :
  --port <n>       Port du primary (defaut: 1556)
  --insecure       Ne pas verifier le certificat TLS
  --dry-run        Afficher le payload de restauration sans l'envoyer
  --timeout <s>    Timeout HTTP (defaut: 120)
  --help

Variables d'environnement equivalentes :
  NBU_PRIMARY NBU_PORT NBU_USER NBU_PASS NBU_DOMAIN NBU_DOMTYPE NBU_APIKEY

Exemple :
  $0 --primary nbu-master.corp.local --apikey \$NBU_APIKEY --dry-run
END
    exit($msg ? 2 : 0);
}

# Appel en toute fin de fichier : les `my` de niveau fichier (dont
# $RECOVERY_PATH) doivent etre initialises avant l'entree dans main().
main();
